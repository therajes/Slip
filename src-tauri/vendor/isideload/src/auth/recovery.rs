//! Narrow transport recovery for an already-authenticated account context.
//! Never classify an Apple rejection/throttle as a reason to replay a code.
use crate::SideloadError;
use rootcause::Report;

pub fn is_transient_auth_failure(error: &Report) -> bool {
    for cause in error.iter_reports() {
        if cause.downcast_current_context::<SideloadError>().is_some() {
            return false;
        }
    }
    let message = error.to_string().to_ascii_lowercase();
    if message.contains("429")
        || message.contains("too many")
        || message.contains("-22979")
        || message.contains("-22981")
    {
        return false;
    }
    message.contains("timed out")
        || message.contains("timeout")
        || message.contains("connection reset")
        || message.contains("connection refused")
        || message.contains("connect error")
        || message.contains("error sending request")
        || message.contains("dns error")
        || message.contains("502")
        || message.contains("503")
        || message.contains("504")
}

#[cfg(test)]
mod tests {
    use super::*;
    use rootcause::prelude::*;
    #[test]
    fn no_recovery_for_rejection_or_throttling() {
        let rejection: Report = report!(SideloadError::AuthWithMessage(
            -21669,
            "Incorrect code HTTP 503".into()
        ))
        .into();
        assert!(!is_transient_auth_failure(&rejection));
        assert!(!is_transient_auth_failure(&report!("HTTP 429")));
        assert!(is_transient_auth_failure(&report!("HTTP 503")));
    }
}
