//! The knowledge vectors every knowledge test reads: what the node knowledge package gives for each input, written by `tests/rust-knowledge-vectors.mts`.

use std::sync::OnceLock;

use serde_json::Value;

/// The parsed `knowledge-vectors.json`, read once per test binary.
pub fn vectors() -> &'static Value {
    static VECTORS: OnceLock<Value> = OnceLock::new();
    VECTORS.get_or_init(|| {
        let file = format!(
            "{}/crates/tagents-core/tests/fixtures/knowledge-vectors.json",
            super::REPO
        );
        serde_json::from_str(&std::fs::read_to_string(file).unwrap()).unwrap()
    })
}

/// What a refused document says when its front matter is not YAML, up to the wording of the YAML error.
pub const YAML_ERROR: &str = "frontmatter is not YAML: ";

/// Whether an error message is the one node gave. The wording of a YAML error is a known difference (the `yaml` package and `saphyr` word the same refusal differently); the refusal and the text before the wording are not.
pub fn same_message(got: &str, want: &str) -> bool {
    if want.starts_with(YAML_ERROR) {
        return got.starts_with(YAML_ERROR);
    }
    got == want
}
