//! Wrapper tools: `[wrapper.<name>]` runs one fixed shell command.
//!
//! The command line is the user's, written into their own config; the agent
//! passes no arguments, so it cannot run anything else through the tool. Stdin
//! is empty. On timeout the whole process group is killed — compilers started
//! by `make` included — so nothing keeps running in the background.

use std::io::Read;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use super::config::{abs_path, expand_env, Wrapper};
use super::conn::Tail;

pub struct RunResult {
    /// -1 when the command did not exit by itself.
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
    pub stdout_truncated: bool,
    pub stderr_truncated: bool,
    pub error: Option<String>,
}

impl RunResult {
    fn failed(error: String) -> Self {
        Self {
            exit_code: -1,
            stdout: String::new(),
            stderr: String::new(),
            stdout_truncated: false,
            stderr_truncated: false,
            error: Some(error),
        }
    }

    pub fn json(&self) -> Value {
        let mut v =
            json!({ "exit_code": self.exit_code, "stdout": self.stdout, "stderr": self.stderr });
        if self.stdout_truncated {
            v["stdout_truncated"] = true.into();
        }
        if self.stderr_truncated {
            v["stderr_truncated"] = true.into();
        }
        if let Some(e) = &self.error {
            v["error"] = e.clone().into();
        }
        v
    }

    /// Structured content plus the same JSON as text; an error unless it exited 0.
    pub fn tool_result(&self) -> Value {
        let v = self.json();
        json!({
            "content": [{ "type": "text", "text": serde_json::to_string_pretty(&v).unwrap_or_default() }],
            "structuredContent": v,
            "isError": self.exit_code != 0 || self.error.is_some(),
        })
    }
}

pub fn definition(name: &str, w: &Wrapper) -> Value {
    let mut desc = if w.description.trim().is_empty() {
        let place = if w.dir.is_empty() {
            "the project directory"
        } else {
            &w.dir
        };
        format!("Run `{}` in {place}.", w.command)
    } else {
        w.description.trim().to_string()
    };
    if !desc.ends_with(['.', '!', '?']) {
        desc.push('.');
    }
    desc.push_str(
        " Takes no arguments. Returns the exit code, stdout and stderr separately; a non-zero \
         exit code is reported as an error.",
    );
    json!({
        "name": name,
        "title": w.command,
        "description": desc,
        "inputSchema": { "type": "object", "properties": {} },
        "outputSchema": {
            "type": "object",
            "properties": {
                "exit_code": { "type": "integer" },
                "stdout": { "type": "string" },
                "stderr": { "type": "string" },
                "stdout_truncated": { "type": "boolean" },
                "stderr_truncated": { "type": "boolean" },
                "error": { "type": "string" },
            },
            "required": ["exit_code", "stdout", "stderr"],
        },
        "annotations": { "title": w.command, "openWorldHint": false },
    })
}

fn working_dir(dir: &str) -> Result<Option<std::path::PathBuf>, String> {
    if dir.is_empty() {
        return Ok(None);
    }
    let abs = abs_path(&expand_env(dir))?;
    if !abs.is_dir() {
        return Err(format!(
            "working directory {:?} does not exist",
            abs.display().to_string()
        ));
    }
    Ok(Some(abs))
}

pub fn run(w: &Wrapper) -> RunResult {
    run_with_timeout(w, w.timeout())
}

pub fn run_with_timeout(w: &Wrapper, timeout: Duration) -> RunResult {
    let dir = match working_dir(&w.dir) {
        Ok(d) => d,
        Err(e) => return RunResult::failed(e),
    };
    let mut cmd = if cfg!(windows) {
        let mut c = Command::new("cmd");
        c.args(["/C", &w.command]);
        c
    } else {
        let mut c = Command::new("/bin/sh");
        c.args(["-c", &w.command]);
        c
    };
    if let Some(d) = dir {
        cmd.current_dir(d);
    }
    for (k, v) in &w.env {
        cmd.env(k, expand_env(v));
    }
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
    }
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return RunResult::failed(format!("could not start /bin/sh: {e}")),
    };

    let limit = w.max_output();
    let collect = |mut r: Box<dyn Read + Send>| {
        let tail = Arc::new(Mutex::new(Tail::new(limit)));
        let t = tail.clone();
        let handle = std::thread::spawn(move || {
            let mut buf = [0u8; 8192];
            while let Ok(n) = r.read(&mut buf) {
                if n == 0 {
                    break;
                }
                t.lock().unwrap().write(&buf[..n]);
            }
        });
        (tail, handle)
    };
    let (out, out_h) = collect(Box::new(child.stdout.take().expect("piped")));
    let (err, err_h) = collect(Box::new(child.stderr.take().expect("piped")));

    let deadline = Instant::now() + timeout;
    let mut error = None;
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break Some(s),
            Ok(None) if Instant::now() >= deadline => {
                kill_group(&mut child);
                error = Some(format!(
                    "timed out after {}; the command was killed",
                    super::conn::human(timeout)
                ));
                break child.wait().ok();
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(20)),
            Err(e) => {
                error = Some(e.to_string());
                break None;
            }
        }
    };
    // A grandchild that escaped the group could hold the pipes open; do not
    // wait on it forever.
    let grace = Instant::now() + Duration::from_secs(5);
    for h in [out_h, err_h] {
        while !h.is_finished() && Instant::now() < grace {
            std::thread::sleep(Duration::from_millis(10));
        }
        if h.is_finished() {
            let _ = h.join();
        }
    }

    let exit_code = match (&error, status.and_then(|s| s.code())) {
        (None, Some(c)) => c,
        _ => -1,
    };
    if error.is_none() && exit_code == -1 {
        error = Some("the command was killed by a signal".into());
    }
    let (out, err) = (out.lock().unwrap(), err.lock().unwrap());
    RunResult {
        exit_code,
        stdout: out.text(),
        stderr: err.text(),
        stdout_truncated: out.truncated,
        stderr_truncated: err.truncated,
        error,
    }
}

fn kill_group(child: &mut std::process::Child) {
    #[cfg(unix)]
    // SAFETY: signalling our own child's process group.
    unsafe {
        libc::kill(-(child.id() as i32), libc::SIGKILL);
    }
    let _ = child.kill();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(command: &str) -> Wrapper {
        Wrapper {
            command: command.into(),
            ..Default::default()
        }
    }

    #[test]
    fn streams_and_exit_code_come_back_separately() {
        let r = run(&w("echo out; echo err >&2; exit 3"));
        assert_eq!(r.exit_code, 3);
        assert_eq!(r.stdout, "out\n");
        assert_eq!(r.stderr, "err\n");
        let v = r.tool_result();
        assert_eq!(v["isError"], true);
        assert_eq!(v["structuredContent"]["exit_code"], 3);
        assert!(run(&w("true")).tool_result()["isError"] == false);
    }

    #[test]
    fn output_keeps_its_end() {
        let mut wr = w("printf 'abcdefghij'");
        wr.max_output = 4;
        let r = run(&wr);
        assert_eq!(r.stdout, "ghij");
        assert!(r.stdout_truncated);
        assert_eq!(r.json()["stdout_truncated"], true);
    }

    #[test]
    fn a_timeout_kills_the_whole_group() {
        let started = Instant::now();
        // The background sleep is a grandchild; it must die with the shell.
        let r = run_with_timeout(&w("sleep 30 & sleep 30"), Duration::from_millis(300));
        assert!(started.elapsed() < Duration::from_secs(5));
        assert_eq!(r.exit_code, -1);
        assert!(r.error.unwrap().contains("timed out"));
    }

    #[test]
    fn env_and_dir_apply() {
        std::env::set_var("NAUTILUS_WRAP_TEST", "hello");
        let mut wr = w("echo $GREETING; pwd");
        wr.env = [("GREETING".into(), "${NAUTILUS_WRAP_TEST}".into())].into();
        wr.dir = "/".into();
        let r = run(&wr);
        assert_eq!(r.stdout, "hello\n/\n");
        wr.dir = "/definitely/not/here".into();
        let r = run(&wr);
        assert_eq!(r.exit_code, -1);
        assert!(r.error.unwrap().contains("does not exist"));
    }

    #[test]
    fn the_definition_says_it_takes_nothing() {
        let d = definition("test", &w("make test"));
        assert_eq!(d["name"], "test");
        let desc = d["description"].as_str().unwrap();
        assert!(
            desc.starts_with("Run `make test` in the project directory."),
            "{desc}"
        );
        assert!(desc.contains("Takes no arguments"));
        assert_eq!(d["inputSchema"]["properties"], json!({}));
    }
}
