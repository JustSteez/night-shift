// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MarketHours} from "../src/lib/MarketHours.sol";

contract MarketHoursTest is Test {
    function _utc(uint256 y, uint256 m, uint256 d, uint256 h, uint256 min) internal pure returns (uint256) {
        return MarketHours.daysFromCivil(y, m, d) * 1 days + h * 1 hours + min * 1 minutes;
    }

    function test_knownDates() public pure {
        assertEq(MarketHours.daysFromCivil(1970, 1, 1), 0);
        assertEq(MarketHours.dayOfWeek(0), 4); // Thursday
        assertEq(MarketHours.dayOfWeek(MarketHours.daysFromCivil(2026, 10, 2)), 5); // Friday
        assertEq(MarketHours.nthSunday(2026, 3, 2), MarketHours.daysFromCivil(2026, 3, 8));
        assertEq(MarketHours.nthSunday(2026, 11, 1), MarketHours.daysFromCivil(2026, 11, 1));
    }

    function test_summerSession() public pure {
        assertFalse(MarketHours.isRegularSession(_utc(2026, 10, 2, 13, 29))); // 09:29 EDT
        assertTrue(MarketHours.isRegularSession(_utc(2026, 10, 2, 13, 30))); // 09:30 EDT
        assertTrue(MarketHours.isRegularSession(_utc(2026, 10, 2, 19, 59))); // 15:59 EDT
        assertFalse(MarketHours.isRegularSession(_utc(2026, 10, 2, 20, 0))); // 16:00 EDT
    }

    function test_winterSession() public pure {
        assertFalse(MarketHours.isRegularSession(_utc(2026, 1, 6, 14, 0))); // 09:00 EST
        assertTrue(MarketHours.isRegularSession(_utc(2026, 1, 6, 15, 0))); // 10:00 EST
        assertFalse(MarketHours.isRegularSession(_utc(2026, 1, 6, 21, 0))); // 16:00 EST
    }

    function test_weekendClosed() public pure {
        assertFalse(MarketHours.isRegularSession(_utc(2026, 10, 3, 15, 0))); // Saturday
        assertFalse(MarketHours.isRegularSession(_utc(2026, 10, 4, 15, 0))); // Sunday
    }

    function test_dstTransitions() public pure {
        // DST starts Sun 2026-03-08.
        assertFalse(MarketHours.isRegularSession(_utc(2026, 3, 6, 13, 45))); // Fri 08:45 EST
        assertTrue(MarketHours.isRegularSession(_utc(2026, 3, 9, 13, 45))); // Mon 09:45 EDT
        // DST ends Sun 2026-11-01.
        assertTrue(MarketHours.isRegularSession(_utc(2026, 10, 30, 13, 45))); // Fri 09:45 EDT
        assertFalse(MarketHours.isRegularSession(_utc(2026, 11, 2, 14, 15))); // Mon 09:15 EST
        assertTrue(MarketHours.isRegularSession(_utc(2026, 11, 2, 14, 45))); // Mon 09:45 EST
    }

    function test_newYorkDayUsesLocalDate() public pure {
        // 02:00 UTC Saturday is still Friday evening in New York.
        assertEq(MarketHours.newYorkDay(_utc(2026, 10, 3, 2, 0)), MarketHours.daysFromCivil(2026, 10, 2));
    }

    function testFuzz_civilRoundTrip(uint32 dayNumber) public pure {
        uint256 z = bound(dayNumber, 0, 200_000);
        (uint256 y, uint256 m, uint256 d) = MarketHours.civilFromDays(z);
        assertEq(MarketHours.daysFromCivil(y, m, d), z);
    }
}
