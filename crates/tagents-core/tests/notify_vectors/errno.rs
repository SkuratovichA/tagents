//! The `errno` section of the notify vectors: node's code and text for each error `node::ERRNOS` names, and no code on either side that the other lacks.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use tagents_core::node::ERRNOS;

use super::section;

#[test]
fn the_errno_table_is_nodes() {
    let vectors = section("errno");
    let vectors = vectors.as_array().unwrap();
    assert_eq!(
        vectors.len(),
        ERRNOS.len(),
        "the table and the vectors name different codes"
    );
    for vector in vectors {
        let code = vector["code"].as_str().unwrap();
        let message = vector["message"].as_str().unwrap();
        let entry = ERRNOS
            .iter()
            .find(|e| e.code == code)
            .unwrap_or_else(|| panic!("{code} is in the vectors and not in the table"));
        assert_eq!(entry.message, message, "{code}");
    }
}
