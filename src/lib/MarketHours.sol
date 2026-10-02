// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MarketHours
/// @notice NYSE regular session (Mon-Fri 09:30-16:00 America/New_York) computed fully onchain,
///         including US daylight saving time. Holidays are handled by the caller.
library MarketHours {
    uint256 internal constant DAY = 1 days;
    uint256 internal constant OPEN_MINUTE = 9 * 60 + 30;
    uint256 internal constant CLOSE_MINUTE = 16 * 60;
    uint256 internal constant EST_OFFSET = 5 hours;
    uint256 internal constant EDT_OFFSET = 4 hours;
    /// @dev DST starts 02:00 EST (07:00 UTC) and ends 02:00 EDT (06:00 UTC).
    uint256 internal constant DST_START_UTC_HOUR = 7;
    uint256 internal constant DST_END_UTC_HOUR = 6;

    /// @notice True during the regular session on a weekday (holidays not considered).
    function isRegularSession(uint256 utcTimestamp) internal pure returns (bool) {
        uint256 local = toNewYorkTime(utcTimestamp);
        uint256 weekday = dayOfWeek(local / DAY);
        if (weekday == 0 || weekday == 6) return false;
        uint256 minuteOfDay = (local % DAY) / 60;
        return minuteOfDay >= OPEN_MINUTE && minuteOfDay < CLOSE_MINUTE;
    }

    /// @notice Days since 1970-01-01 in New York local time. Used as the key for holidays.
    function newYorkDay(uint256 utcTimestamp) internal pure returns (uint256) {
        return toNewYorkTime(utcTimestamp) / DAY;
    }

    function toNewYorkTime(uint256 utcTimestamp) internal pure returns (uint256) {
        return utcTimestamp - (isDaylightSaving(utcTimestamp) ? EDT_OFFSET : EST_OFFSET);
    }

    /// @notice US rule: second Sunday of March to first Sunday of November.
    function isDaylightSaving(uint256 utcTimestamp) internal pure returns (bool) {
        (uint256 year,,) = civilFromDays(utcTimestamp / DAY);
        uint256 start = nthSunday(year, 3, 2) * DAY + DST_START_UTC_HOUR * 1 hours;
        uint256 end = nthSunday(year, 11, 1) * DAY + DST_END_UTC_HOUR * 1 hours;
        return utcTimestamp >= start && utcTimestamp < end;
    }

    /// @return 0 = Sunday ... 6 = Saturday. 1970-01-01 was a Thursday.
    function dayOfWeek(uint256 daysSinceEpoch) internal pure returns (uint256) {
        return (daysSinceEpoch + 4) % 7;
    }

    /// @notice Days since epoch of the nth Sunday of a month.
    function nthSunday(uint256 year, uint256 month, uint256 n) internal pure returns (uint256) {
        uint256 first = daysFromCivil(year, month, 1);
        uint256 toSunday = (7 - dayOfWeek(first)) % 7;
        return first + toSunday + (n - 1) * 7;
    }

    /// @dev Howard Hinnant's days_from_civil, restricted to years >= 1970.
    function daysFromCivil(uint256 y, uint256 m, uint256 d) internal pure returns (uint256) {
        if (m <= 2) y -= 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 mp = m > 2 ? m - 3 : m + 9;
        uint256 doy = (153 * mp + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146097 + doe - 719468;
    }

    /// @dev Howard Hinnant's civil_from_days.
    function civilFromDays(uint256 z) internal pure returns (uint256 y, uint256 m, uint256 d) {
        z += 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        d = doy - (153 * mp + 2) / 5 + 1;
        m = mp < 10 ? mp + 3 : mp - 9;
        y = yoe + era * 400 + (m <= 2 ? 1 : 0);
    }
}
