use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum ConfigMode {
    Overwrite,
    Merge,
}

/// Deep-merges `operator` config into `existing` config.
/// Operator values win on conflict; existing keys not in operator config are preserved.
pub fn merge_config(operator: &Value, existing: &Value) -> Value {
    match (operator, existing) {
        (Value::Object(op), Value::Object(ex)) => {
            let mut merged = ex.clone();
            for (k, v) in op {
                let entry = merged.remove(k).unwrap_or(Value::Null);
                merged.insert(k.clone(), merge_config(v, &entry));
            }
            Value::Object(merged)
        }
        _ => operator.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn operator_keys_override_existing() {
        let existing = json!({"a": 1, "b": 2});
        let operator = json!({"b": 99});
        let result = merge_config(&operator, &existing);
        assert_eq!(result, json!({"a": 1, "b": 99}));
    }

    #[test]
    fn existing_keys_preserved() {
        let existing = json!({"keep": "me", "also": "here"});
        let operator = json!({"new": "value"});
        let result = merge_config(&operator, &existing);
        assert_eq!(
            result,
            json!({"keep": "me", "also": "here", "new": "value"})
        );
    }

    #[test]
    fn nested_objects_deep_merged() {
        let existing = json!({"nested": {"a": 1, "b": 2}, "top": "val"});
        let operator = json!({"nested": {"b": 99, "c": 3}});
        let result = merge_config(&operator, &existing);
        assert_eq!(
            result,
            json!({"nested": {"a": 1, "b": 99, "c": 3}, "top": "val"})
        );
    }

    #[test]
    fn overwrite_mode_replaces_entirely() {
        let existing = json!({"a": 1});
        let operator = json!({"b": 2});
        // In Overwrite mode, just use operator config directly
        let result = match ConfigMode::Overwrite {
            ConfigMode::Overwrite => operator.clone(),
            ConfigMode::Merge => merge_config(&operator, &existing),
        };
        assert_eq!(result, json!({"b": 2}));
    }
}
