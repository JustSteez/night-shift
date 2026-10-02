// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {NightShiftVault} from "../src/NightShiftVault.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MarketHours} from "../src/lib/MarketHours.sol";
import {MockToken, MockFeed} from "./mocks/Mocks.sol";

contract NightShiftVaultTest is Test {
    NightShiftVault vault;
    MockToken usdg;
    MockToken tsla;
    MockFeed tslaFeed;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");

    uint256 constant USDG = 1e6;
    uint256 constant SPREAD = 50; // 0.5%
    int256 constant TSLA_PRICE = 250e8;
    uint256 friOpen; // Fri 2026-10-02 10:00 EDT
    uint256 friNight; // Fri 2026-10-02 20:00 EDT

    function setUp() public {
        friOpen = MarketHours.daysFromCivil(2026, 10, 2) * 1 days + 14 hours;
        friNight = friOpen + 10 hours;
        vm.warp(friOpen);

        usdg = new MockToken("USDG", "USDG", 6);
        tsla = new MockToken("Tesla Stock Token", "TSLA", 18);
        tslaFeed = new MockFeed(TSLA_PRICE);
        vault = new NightShiftVault(usdg, owner, agent, SPREAD, 50_000 * USDG);
        vm.prank(owner);
        vault.listStock(address(tsla), AggregatorV3Interface(address(tslaFeed)), 3_000);

        usdg.mint(lp, 100_000 * USDG);
        tsla.mint(trader, 1_000 ether);
        usdg.mint(trader, 100_000 * USDG);
        vm.prank(lp);
        usdg.approve(address(vault), type(uint256).max);
        vm.startPrank(trader);
        usdg.approve(address(vault), type(uint256).max);
        tsla.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.prank(lp);
        vault.deposit(100_000 * USDG, 0);
    }

    // ------------------------------------------------------------ LP flows

    function test_depositMintsSharesAtNav() public view {
        assertEq(vault.nav(), 100_000 * USDG);
        assertGt(vault.balanceOf(lp), 0);
        assertEq(vault.decimals(), 6);
    }

    function test_revertWhen_depositAfterHours() public {
        vm.warp(friNight);
        vm.prank(lp);
        vm.expectRevert(NightShiftVault.MarketClosed.selector);
        vault.deposit(1, 0);
    }

    function test_revertWhen_depositZeroOrSlippage() public {
        vm.startPrank(lp);
        vm.expectRevert(NightShiftVault.ZeroAmount.selector);
        vault.deposit(0, 0);
        usdg.mint(lp, 1 * USDG);
        vm.expectRevert(NightShiftVault.Slippage.selector);
        vault.deposit(1 * USDG, type(uint256).max);
        vm.stopPrank();
    }

    function test_sharesLockedForOneDay() public {
        uint256 shares = vault.balanceOf(lp);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(NightShiftVault.SharesLocked.selector, friOpen + 1 days));
        vault.withdraw(shares);

        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(NightShiftVault.SharesLocked.selector, friOpen + 1 days));
        vault.transfer(trader, 1);
    }

    function test_withdrawPaysProRataInKind() public {
        _deskSell(10 ether);
        vm.warp(friOpen + 1 days + 1);
        uint256 shares = vault.balanceOf(lp);
        vm.prank(lp);
        vault.withdraw(shares / 2);
        assertEq(tsla.balanceOf(lp), 5 ether);
        assertApproxEqAbs(usdg.balanceOf(lp), (100_000 * USDG - 2_487_500_000) / 2, 1);
    }

    function test_revertWhen_withdrawZero() public {
        vm.prank(lp);
        vm.expectRevert(NightShiftVault.ZeroAmount.selector);
        vault.withdraw(0);
    }

    // ------------------------------------------------------------ Desk

    function test_sellAtLastCloseMinusSpread() public {
        uint256 out = _deskSell(10 ether);
        // 10 TSLA * $250 = $2,500, minus 0.5%
        assertEq(out, 2_487_500_000);
        assertEq(tsla.balanceOf(address(vault)), 10 ether);
    }

    function test_buyAtLastClosePlusSpread() public {
        _deskSell(10 ether);
        vm.prank(trader);
        uint256 out = vault.buy(address(tsla), 1_005 * USDG, 0);
        // $1,005 / 1.005 = $1,000 of TSLA = 4 TSLA
        assertEq(out, 4 ether);
    }

    function test_spreadProfitAccruesToLps() public {
        _deskSell(10 ether);
        vm.prank(trader);
        vault.buy(address(tsla), 2_512_500_000, 0);
        assertEq(tsla.balanceOf(address(vault)), 0);
        assertEq(vault.nav(), 100_025 * USDG);
    }

    function test_revertWhen_deskTradesDuringMarketHours() public {
        vm.prank(trader);
        vm.expectRevert(NightShiftVault.MarketOpen.selector);
        vault.sell(address(tsla), 1 ether, 0);
    }

    function test_deskOpenOnWeekend() public {
        vm.warp(friOpen + 1 days); // Saturday
        assertFalse(vault.isMarketOpen());
        vm.prank(trader);
        vault.sell(address(tsla), 1 ether, 0);
    }

    function test_revertWhen_noInventoryToSell() public {
        vm.warp(friNight);
        vm.prank(trader);
        vm.expectRevert(NightShiftVault.InsufficientInventory.selector);
        vault.buy(address(tsla), 100 * USDG, 0);
    }

    function test_revertWhen_exposureExceeded() public {
        vm.warp(friNight);
        vm.prank(trader);
        vm.expectRevert(NightShiftVault.ExposureExceeded.selector);
        vault.sell(address(tsla), 160 ether, 0); // $40k of TSLA = ~40% of NAV, cap is 30%
    }

    function test_revertWhen_tradeTooLargeOrSlippage() public {
        vm.warp(friNight);
        vm.startPrank(trader);
        vm.expectRevert(NightShiftVault.TradeTooLarge.selector);
        vault.sell(address(tsla), 202 ether, 0);
        vm.expectRevert(NightShiftVault.Slippage.selector);
        vault.sell(address(tsla), 1 ether, type(uint256).max);
        vm.expectRevert(NightShiftVault.ZeroAmount.selector);
        vault.sell(address(tsla), 0, 0);
        vm.stopPrank();
    }

    function test_revertWhen_priceStale() public {
        vm.warp(friNight + 5 days + 1);
        vm.prank(trader);
        vm.expectRevert(NightShiftVault.StalePrice.selector);
        vault.sell(address(tsla), 1 ether, 0);
    }

    function test_revertWhen_unknownOrDisabledStock() public {
        vm.warp(friNight);
        vm.prank(trader);
        vm.expectRevert(NightShiftVault.UnknownStock.selector);
        vault.sell(address(usdg), 1, 0);

        vm.prank(owner);
        vault.updateStock(address(tsla), false, 3_000);
        vm.prank(trader);
        vm.expectRevert(NightShiftVault.StockDisabled.selector);
        vault.sell(address(tsla), 1 ether, 0);
    }

    function test_holidayOpensDeskDuringDay() public {
        vm.prank(owner);
        vault.setHoliday(MarketHours.newYorkDay(friOpen), true);
        assertFalse(vault.isMarketOpen());
        vm.prank(trader);
        vault.sell(address(tsla), 1 ether, 0);
    }

    // ------------------------------------------------------------ Agent & owner bounds

    function test_agentSetsSpreadWithinBounds() public {
        vm.startPrank(agent);
        vault.setSpread(200);
        assertEq(vault.spreadBps(), 200);
        vm.expectRevert(NightShiftVault.BadSpread.selector);
        vault.setSpread(5);
        vm.expectRevert(NightShiftVault.BadSpread.selector);
        vault.setSpread(1_001);
        vm.stopPrank();

        vm.prank(trader);
        vm.expectRevert(NightShiftVault.NotAgent.selector);
        vault.setSpread(100);
    }

    function test_agentCanPauseButOnlyOwnerUnpauses() public {
        vm.prank(agent);
        vault.pauseDesk();
        vm.warp(friNight);
        vm.prank(trader);
        vm.expectRevert(NightShiftVault.DeskIsPaused.selector);
        vault.sell(address(tsla), 1 ether, 0);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        vault.unpauseDesk();

        vm.prank(owner);
        vault.unpauseDesk();
        vm.prank(trader);
        vault.sell(address(tsla), 1 ether, 0);
    }

    function test_listStockValidation() public {
        MockToken nvda = new MockToken("NVDA", "NVDA", 18);
        MockFeed feed = new MockFeed(180e8);
        vm.startPrank(owner);
        vm.expectRevert(NightShiftVault.AlreadyListed.selector);
        vault.listStock(address(tsla), AggregatorV3Interface(address(tslaFeed)), 1_000);
        vm.expectRevert(NightShiftVault.InvalidAddress.selector);
        vault.listStock(address(usdg), AggregatorV3Interface(address(feed)), 1_000);
        vm.expectRevert(NightShiftVault.BadExposure.selector);
        vault.listStock(address(nvda), AggregatorV3Interface(address(feed)), 3_001);
        vault.listStock(address(nvda), AggregatorV3Interface(address(feed)), 1_000);
        vm.expectRevert(NightShiftVault.UnknownStock.selector);
        vault.updateStock(makeAddr("x"), true, 1_000);
        vm.stopPrank();
        assertEq(vault.stockList().length, 2);
    }

    function test_ownerAdminAndAccessControl() public {
        vm.startPrank(owner);
        vault.setAgent(trader);
        vault.setMaxTrade(1 * USDG);
        vm.expectRevert(NightShiftVault.InvalidAddress.selector);
        vault.setAgent(address(0));
        vm.expectRevert(NightShiftVault.ZeroAmount.selector);
        vault.setMaxTrade(0);
        vm.stopPrank();
        assertEq(vault.agent(), trader);
        assertEq(vault.maxTradeUsdg(), 1 * USDG);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent));
        vault.setHoliday(1, true);
    }

    function test_secondDepositorGetsFairShares() public {
        _deskSell(10 ether);
        vm.prank(trader);
        vault.buy(address(tsla), 2_512_500_000, 0); // vault now worth $100,025
        vm.warp(friOpen + 3 days); // Monday 10:00 EDT
        tslaFeed.set(TSLA_PRICE);

        address lp2 = makeAddr("lp2");
        usdg.mint(lp2, 100_025 * USDG);
        vm.startPrank(lp2);
        usdg.approve(address(vault), type(uint256).max);
        vault.deposit(100_025 * USDG, 0);
        vm.stopPrank();
        assertApproxEqRel(vault.balanceOf(lp2), vault.balanceOf(lp), 1e12);
    }

    function testFuzz_roundTripNeverDrainsVault(uint96 amount) public {
        uint256 stockIn = bound(amount, 1e15, 100 ether);
        uint256 navBefore = vault.nav();
        uint256 usdgOut = _deskSell(stockIn);
        vm.prank(trader);
        vault.buy(address(tsla), usdgOut, 0);
        assertGe(vault.nav(), navBefore);
    }

    function _deskSell(uint256 stockIn) internal returns (uint256 out) {
        vm.warp(friNight);
        vm.prank(trader);
        out = vault.sell(address(tsla), stockIn, 0);
    }
}
