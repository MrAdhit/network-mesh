//! Small shared helpers.

/// The commit these binaries were built from, stamped in by the build script.
pub const GIT_SHA: &str = env!("MESH_GIT_SHA");

/// One line identifying a build, for `--version` and for bug reports.
///
/// The version is a claim and the commit is the thing itself, so both are printed. The target
/// triple is here because half the platform-specific failures in this project look identical
/// until you know which build is running.
pub fn version_line(binary: &str) -> String {
    format!(
        "{binary} {} ({}) {}",
        env!("CARGO_PKG_VERSION"),
        GIT_SHA,
        crate::update::TARGET
    )
}

/// Keep a file to its owner: mode 0600 on unix.
///
/// Every caller is writing a credential, and the directories these land in are traversable on
/// purpose: the state directory so a non-root client can reach the daemon's socket, a user's
/// config directory because it is theirs. So the file carries its own protection rather than
/// relying on the directory's, or on the umask being sane.
///
/// Best effort on Windows, where ACL inheritance from ProgramData and AppData already gives
/// roughly this and doing better needs the Win32 security APIs.
pub(crate) fn restrict(path: &std::path::Path) -> anyhow::Result<()> {
    #[cfg(unix)]
    {
        use anyhow::Context;
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .with_context(|| format!("restricting {}", path.display()))?;
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

/// Seconds since the unix epoch.
pub fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

/// Split a unix timestamp into (year, month, day, hour, minute, second) UTC.
///
/// Howard Hinnant's civil-from-days. Cheaper than taking a date-time dependency for the two
/// places that need to render a timestamp.
pub fn civil_utc(ts: i64) -> (i64, i64, i64, i64, i64, i64) {
    let (days, secs) = (ts.div_euclid(86_400), ts.rem_euclid(86_400));
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d, secs / 3600, (secs % 3600) / 60, secs % 60)
}

/// RFC 3339 in UTC, e.g. `2026-07-25T13:33:25Z`.
pub fn rfc3339(ts: i64) -> String {
    let (y, m, d, hh, mm, ss) = civil_utc(ts);
    format!("{y:04}-{m:02}-{d:02}T{hh:02}:{mm:02}:{ss:02}Z")
}

pub fn now_rfc3339() -> String {
    rfc3339(now_unix())
}

/// Cloudflare wants `2026-07-25T13:33:25.000+00:00` for the ToS acceptance stamp.
pub fn cf_timestamp() -> String {
    let (y, m, d, hh, mm, ss) = civil_utc(now_unix());
    format!("{y:04}-{m:02}-{d:02}T{hh:02}:{mm:02}:{ss:02}.000+00:00")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_timestamps_render_correctly() {
        assert_eq!(rfc3339(0), "1970-01-01T00:00:00Z");
        assert_eq!(rfc3339(1_784_986_405), "2026-07-25T13:33:25Z");
        assert!(cf_timestamp().ends_with(".000+00:00"));
    }
}
