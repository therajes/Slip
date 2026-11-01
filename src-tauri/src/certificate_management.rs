//! Destructive operations require an explicit, fully validated selection. No
//! mutation in this module is retried automatically, including uncertain results.
use crate::error::AppError;
use futures::future::BoxFuture;
use std::collections::HashSet;

pub(crate) fn validate_selection(
    selected: &[String],
    available: &[String],
    expected: Option<&[String]>,
) -> Result<Vec<String>, AppError> {
    if selected.is_empty() {
        return Err(AppError::Developer(
            "Select at least one certificate to revoke.".into(),
        ));
    }
    let current: HashSet<&str> = available.iter().map(String::as_str).collect();
    let mut unique = HashSet::new();
    for serial in selected {
        if serial.is_empty() || serial.trim() != serial || !unique.insert(serial.as_str()) {
            return Err(AppError::Developer("The certificate selection is invalid. Refresh the list and select each certificate once.".into()));
        }
        if !current.contains(serial.as_str()) {
            return Err(AppError::Developer("The selected certificate no longer belongs to this account. Refresh the list and select it again.".into()));
        }
    }
    if let Some(expected) = expected {
        let snapshot: HashSet<&str> = expected.iter().map(String::as_str).collect();
        if snapshot.len() != expected.len() || snapshot != current {
            return Err(AppError::Developer("The certificate list changed after confirmation. Refresh the list and confirm your selection again. No certificates were revoked.".into()));
        }
    }
    Ok(selected.to_vec())
}

pub(crate) struct RevocationOutcome {
    pub revoked: Vec<String>,
    pub unconfirmed: Vec<String>,
    pub not_attempted: Vec<String>,
}
impl RevocationOutcome {
    pub fn completed(&self) -> bool {
        self.unconfirmed.is_empty()
    }
    pub fn message(&self) -> String {
        let total = self.revoked.len() + self.unconfirmed.len() + self.not_attempted.len();
        if self.completed() {
            format!(
                "Revoked {} certificate{}. Apps signed with these certificates may stop opening until signed again.",
                self.revoked.len(),
                if self.revoked.len() == 1 { "" } else { "s" }
            )
        } else {
            format!(
                "{} of {total} certificates were confirmed revoked. Apple could not confirm the next revocation; {} were not attempted. Refresh the certificate list before trying again. Apps using revoked certificates may need to be signed again.",
                self.revoked.len(),
                self.not_attempted.len()
            )
        }
    }
}

pub(crate) async fn revoke_selected<C>(
    context: &mut C,
    selected: &[String],
    operation: for<'a> fn(&'a mut C, &'a str) -> BoxFuture<'a, Result<(), AppError>>,
) -> RevocationOutcome {
    let mut outcome = RevocationOutcome {
        revoked: vec![],
        unconfirmed: vec![],
        not_attempted: vec![],
    };
    for (index, serial) in selected.iter().enumerate() {
        // Stop on an uncertain response. Replaying this request or continuing
        // with other certificates would extend a destructive partial operation.
        if operation(context, serial).await.is_err() {
            outcome.unconfirmed.push(serial.clone());
            outcome
                .not_attempted
                .extend_from_slice(&selected[index + 1..]);
            break;
        }
        outcome.revoked.push(serial.clone());
    }
    outcome
}

#[cfg(test)]
mod tests {
    use super::*;
    fn serials(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }
    #[test]
    fn selected_and_all_are_explicit_subsets_of_the_current_snapshot() {
        let current = serials(&["A", "B", "C"]);
        assert_eq!(
            validate_selection(&serials(&["B"]), &current, Some(&current)).unwrap(),
            serials(&["B"])
        );
        assert_eq!(
            validate_selection(&current, &current, Some(&current)).unwrap(),
            current
        );
        for invalid in [
            serials(&[]),
            serials(&["A", "A"]),
            serials(&["D"]),
            serials(&[" A"]),
        ] {
            assert!(validate_selection(&invalid, &current, Some(&current)).is_err());
        }
        assert!(
            validate_selection(&serials(&["A"]), &current, Some(&serials(&["A", "B"]))).is_err()
        );
    }
    struct FakeApi {
        calls: Vec<String>,
        fail_at: Option<usize>,
    }
    fn revoke_fixture<'a>(
        api: &'a mut FakeApi,
        serial: &'a str,
    ) -> BoxFuture<'a, Result<(), AppError>> {
        Box::pin(async move {
            api.calls.push(serial.into());
            if api.fail_at == Some(api.calls.len()) {
                Err(AppError::Misc("HTTP 503 sensitive-fixture".into()))
            } else {
                Ok(())
            }
        })
    }
    #[tokio::test]
    async fn partial_failure_stops_and_never_retries_a_mutation() {
        let mut api = FakeApi {
            calls: vec![],
            fail_at: Some(2),
        };
        let outcome = revoke_selected(&mut api, &serials(&["A", "B", "C"]), revoke_fixture).await;
        assert_eq!(api.calls, serials(&["A", "B"]));
        assert_eq!(outcome.revoked, serials(&["A"]));
        assert_eq!(outcome.unconfirmed, serials(&["B"]));
        assert_eq!(outcome.not_attempted, serials(&["C"]));
        assert!(!outcome.message().contains("sensitive-fixture"));
        assert!(outcome.message().contains("1 of 3"));
    }
    #[tokio::test]
    async fn all_confirmed_targets_are_revoked_once() {
        let mut api = FakeApi {
            calls: vec![],
            fail_at: None,
        };
        let selected = serials(&["A", "B"]);
        let outcome = revoke_selected(&mut api, &selected, revoke_fixture).await;
        assert!(outcome.completed());
        assert_eq!(api.calls, selected);
        assert_eq!(outcome.revoked, selected);
    }
}
