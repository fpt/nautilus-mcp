//! Tool search with the query forms of Claude Code's ToolSearch:
//!
//! - `select:a,b` — exactly these, in this order;
//! - `+term` — `term` must appear in the tool name;
//! - other terms rank: 10 for the whole name, 5 for one word of it, 3 for a
//!   substring of it, 2 for the title or description, 1 for a parameter name.
//!
//! An empty query matches everything. It exists because clients cache tool
//! definitions: a tool added by a rebuild is invisible to the client's own
//! search until it reconnects.

use serde_json::Value;

pub struct SearchResult {
    pub tools: Vec<Value>,
    pub total: usize,
    pub missing: Vec<String>,
}

fn name(t: &Value) -> &str {
    t.get("name").and_then(Value::as_str).unwrap_or("")
}

pub fn search(tools: &[Value], query: &str, max_results: usize) -> SearchResult {
    let query = query.trim();
    if let Some(names) = query.strip_prefix("select:") {
        let mut res = SearchResult {
            tools: vec![],
            total: 0,
            missing: vec![],
        };
        for n in names.split(',').map(str::trim).filter(|n| !n.is_empty()) {
            match tools.iter().find(|t| name(t) == n) {
                Some(t) => res.tools.push(t.clone()),
                None => res.missing.push(n.to_string()),
            }
        }
        res.total = res.tools.len();
        return res;
    }

    let lower = query.to_lowercase();
    let (mut required, mut optional) = (Vec::new(), Vec::new());
    for term in lower.split_whitespace() {
        match term.strip_prefix('+') {
            Some("") => {}
            Some(t) => required.push(t),
            None => optional.push(term),
        }
    }

    let mut matches: Vec<(i64, &Value)> = Vec::new();
    for t in tools {
        let doc = Doc::new(t);
        if !required.iter().all(|r| doc.name.contains(r)) {
            continue;
        }
        let mut score: i64 = optional.iter().map(|o| doc.score(o)).sum();
        if !optional.is_empty() && score == 0 {
            continue;
        }
        score += required.iter().map(|r| doc.score(r)).sum::<i64>();
        matches.push((score, t));
    }
    matches.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| name(a.1).cmp(name(b.1))));
    let total = matches.len();
    let limit = if max_results == 0 {
        usize::MAX
    } else {
        max_results
    };
    SearchResult {
        tools: matches
            .into_iter()
            .take(limit)
            .map(|(_, t)| t.clone())
            .collect(),
        total,
        missing: vec![],
    }
}

struct Doc {
    name: String,
    words: Vec<String>,
    desc: String,
    params: Vec<String>,
}

impl Doc {
    fn new(t: &Value) -> Self {
        let s = |k: &str| t.get(k).and_then(Value::as_str).unwrap_or("");
        Self {
            name: name(t).to_lowercase(),
            words: split_words(name(t)),
            desc: format!("{} {}", s("title"), s("description")).to_lowercase(),
            params: t
                .pointer("/inputSchema/properties")
                .and_then(Value::as_object)
                .map(|o| o.keys().map(|k| k.to_lowercase()).collect())
                .unwrap_or_default(),
        }
    }

    fn score(&self, term: &str) -> i64 {
        let mut score = 0;
        if self.name == term {
            score += 10;
        } else if self.words.iter().any(|w| w == term) {
            score += 5;
        } else if self.name.contains(term) {
            score += 3;
        }
        if self.desc.contains(term) {
            score += 2;
        }
        if self.params.iter().any(|p| p.contains(term)) {
            score += 1;
        }
        score
    }
}

/// `getHTTPStatus_v2` → `get http status v2`.
pub fn split_words(s: &str) -> Vec<String> {
    let chars: Vec<char> = s.chars().collect();
    let mut words = Vec::new();
    let mut cur = String::new();
    for (i, &c) in chars.iter().enumerate() {
        if !c.is_alphanumeric() {
            if !cur.is_empty() {
                words.push(std::mem::take(&mut cur).to_lowercase());
            }
            continue;
        }
        if c.is_uppercase() && !cur.is_empty() {
            let prev = chars[i - 1];
            let next_lower = chars.get(i + 1).is_some_and(|n| n.is_lowercase());
            if prev.is_lowercase() || prev.is_ascii_digit() || (prev.is_uppercase() && next_lower) {
                words.push(std::mem::take(&mut cur).to_lowercase());
            }
        }
        cur.push(c);
    }
    if !cur.is_empty() {
        words.push(cur.to_lowercase());
    }
    words
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn tools() -> Vec<Value> {
        vec![
            json!({"name": "godev__search_godoc", "description": "Search pkg.go.dev",
                   "inputSchema": {"properties": {"query": {}}}}),
            json!({"name": "godev__read_godoc", "description": "Read a package's docs"}),
            json!({"name": "web__search", "description": "Search the web",
                   "inputSchema": {"properties": {"q": {}}}}),
        ]
    }

    #[test]
    fn words_split_on_case_and_punctuation() {
        assert_eq!(
            split_words("getHTTPStatus_v2"),
            vec!["get", "http", "status", "v2"]
        );
        assert_eq!(
            split_words("godev__search_godoc"),
            vec!["godev", "search", "godoc"]
        );
    }

    #[test]
    fn keywords_rank_and_required_terms_filter() {
        let r = search(&tools(), "search", 5);
        assert_eq!(r.total, 2);
        let r = search(&tools(), "+godev__ search", 5);
        assert_eq!(r.total, 1);
        assert_eq!(r.tools[0]["name"], "godev__search_godoc");
        let r = search(&tools(), "query", 5);
        assert_eq!(r.tools[0]["name"], "godev__search_godoc");
        assert_eq!(search(&tools(), "", 0).total, 3);
        assert_eq!(search(&tools(), "", 1).tools.len(), 1);
        assert_eq!(search(&tools(), "nothing-like-it", 5).total, 0);
    }

    #[test]
    fn select_keeps_order_and_reports_missing() {
        let r = search(&tools(), "select:web__search, nope ,godev__read_godoc", 1);
        let names: Vec<_> = r
            .tools
            .iter()
            .map(|t| t["name"].as_str().unwrap())
            .collect();
        assert_eq!(names, vec!["web__search", "godev__read_godoc"]);
        assert_eq!(r.missing, vec!["nope"]);
    }
}
