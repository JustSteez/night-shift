// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {MarketHours} from "./lib/MarketHours.sol";

/// @title NightShiftVault
/// @notice Wall Street closes at 4pm. Night Shift doesn't.
///         While the NYSE is closed, the vault quotes Robinhood Stock Tokens at the last Chainlink price
///         plus or minus a spread. Liquidity providers deposit USDG while the market is open and earn the spread.
///         An AI agent tunes the spread inside hard bounds and can pause the desk. Neither the agent nor the
///         owner can move vault funds: assets only leave through trades or pro-rata withdrawals.
contract NightShiftVault is ERC20, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20Metadata;

    struct Stock {
        AggregatorV3Interface feed;
        uint16 maxExposureBps;
        uint8 tokenDecimals;
        uint8 feedDecimals;
        bool listed;
        bool enabled;
    }

    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_SPREAD_BPS = 10;
    uint256 public constant MAX_SPREAD_BPS = 1_000;
    uint256 public constant MAX_EXPOSURE_BPS = 3_000;
    uint256 public constant MAX_STOCKS = 20;
    uint256 public constant MAX_PRICE_AGE = 5 days;
    uint256 public constant SHARE_LOCK = 1 days;
    uint256 private constant VIRTUAL_SHARES = 1e6;

    IERC20Metadata public immutable usdg;
    uint8 private immutable _usdgDecimals;

    address public agent;
    uint256 public spreadBps;
    uint256 public maxTradeUsdg;
    bool public deskPaused;

    mapping(address => Stock) public stocks;
    address[] private _stockList;
    mapping(uint256 => bool) public isHoliday;
    mapping(address => uint256) public unlockAt;

    event Deposited(address indexed account, uint256 assets, uint256 shares);
    event Withdrawn(address indexed account, uint256 shares);
    event Traded(address indexed trader, address indexed stock, bool buy, uint256 usdgAmount, uint256 stockAmount);
    event StockListed(address indexed stock, address feed, uint256 maxExposureBps);
    event StockUpdated(address indexed stock, bool enabled, uint256 maxExposureBps);
    event SpreadSet(uint256 spreadBps);
    event AgentSet(address indexed agent);
    event MaxTradeSet(uint256 maxTradeUsdg);
    event HolidaySet(uint256 indexed newYorkDay, bool closed);
    event DeskPaused(address indexed by);
    event DeskUnpaused();

    error MarketOpen();
    error MarketClosed();
    error DeskIsPaused();
    error NotAgent();
    error BadSpread();
    error BadExposure();
    error UnknownStock();
    error StockDisabled();
    error AlreadyListed();
    error TooManyStocks();
    error InvalidAddress();
    error StalePrice();
    error ZeroAmount();
    error TradeTooLarge();
    error Slippage();
    error InsufficientInventory();
    error ExposureExceeded();
    error SharesLocked(uint256 until);

    modifier onlyAgentOrOwner() {
        if (msg.sender != agent && msg.sender != owner()) revert NotAgent();
        _;
    }

    modifier whenMarketOpen() {
        if (!isMarketOpen()) revert MarketClosed();
        _;
    }

    modifier whenDeskOpen() {
        if (isMarketOpen()) revert MarketOpen();
        if (deskPaused) revert DeskIsPaused();
        _;
    }

    constructor(IERC20Metadata usdg_, address owner_, address agent_, uint256 spreadBps_, uint256 maxTradeUsdg_)
        ERC20("Night Shift USDG", "nsUSDG")
        Ownable(owner_)
    {
        if (address(usdg_) == address(0)) revert InvalidAddress();
        usdg = usdg_;
        _usdgDecimals = usdg_.decimals();
        _setAgent(agent_);
        _setSpread(spreadBps_);
        _setMaxTrade(maxTradeUsdg_);
    }

    // ---------------------------------------------------------------- LPs (market hours)

    /// @notice Deposit USDG at current NAV. Only while the NYSE is open, so prices are live.
    function deposit(uint256 assets, uint256 minShares) external nonReentrant whenMarketOpen returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        shares = Math.mulDiv(assets, totalSupply() + VIRTUAL_SHARES, nav() + 1);
        if (shares < minShares) revert Slippage();
        usdg.safeTransferFrom(msg.sender, address(this), assets);
        unlockAt[msg.sender] = block.timestamp + SHARE_LOCK;
        _mint(msg.sender, shares);
        emit Deposited(msg.sender, assets, shares);
    }

    /// @notice Burn shares for a pro-rata slice of every asset in the vault (USDG + stock tokens).
    ///         Oracle-free, so it works any time.
    function withdraw(uint256 shares) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        uint256 supply = totalSupply();
        uint256 usdgOut = Math.mulDiv(usdg.balanceOf(address(this)), shares, supply);
        uint256 n = _stockList.length;
        uint256[] memory stockOut = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            stockOut[i] = Math.mulDiv(IERC20Metadata(_stockList[i]).balanceOf(address(this)), shares, supply);
        }
        _burn(msg.sender, shares);
        if (usdgOut > 0) usdg.safeTransfer(msg.sender, usdgOut);
        for (uint256 i; i < n; ++i) {
            if (stockOut[i] > 0) IERC20Metadata(_stockList[i]).safeTransfer(msg.sender, stockOut[i]);
        }
        emit Withdrawn(msg.sender, shares);
    }

    // ---------------------------------------------------------------- Desk (after hours)

    /// @notice Buy stock tokens with USDG at last close + spread.
    function buy(address stock, uint256 usdgIn, uint256 minStockOut)
        external
        nonReentrant
        whenDeskOpen
        returns (uint256 stockOut)
    {
        stockOut = quoteBuy(stock, usdgIn);
        if (stockOut < minStockOut) revert Slippage();
        if (stockOut > IERC20Metadata(stock).balanceOf(address(this))) revert InsufficientInventory();
        usdg.safeTransferFrom(msg.sender, address(this), usdgIn);
        IERC20Metadata(stock).safeTransfer(msg.sender, stockOut);
        emit Traded(msg.sender, stock, true, usdgIn, stockOut);
    }

    /// @notice Sell stock tokens for USDG at last close - spread. Capped by per-stock exposure.
    function sell(address stock, uint256 stockIn, uint256 minUsdgOut)
        external
        nonReentrant
        whenDeskOpen
        returns (uint256 usdgOut)
    {
        usdgOut = quoteSell(stock, stockIn);
        if (usdgOut < minUsdgOut) revert Slippage();
        if (usdgOut > usdg.balanceOf(address(this))) revert InsufficientInventory();
        IERC20Metadata(stock).safeTransferFrom(msg.sender, address(this), stockIn);
        usdg.safeTransfer(msg.sender, usdgOut);
        if (exposureBps(stock) > stocks[stock].maxExposureBps) revert ExposureExceeded();
        emit Traded(msg.sender, stock, false, usdgOut, stockIn);
    }

    function quoteBuy(address stock, uint256 usdgIn) public view returns (uint256) {
        Stock memory s = _tradable(stock);
        if (usdgIn == 0) revert ZeroAmount();
        if (usdgIn > maxTradeUsdg) revert TradeTooLarge();
        uint256 askValue = Math.mulDiv(usdgIn, BPS, BPS + spreadBps);
        return _usdgToStock(s, askValue, _price(s));
    }

    function quoteSell(address stock, uint256 stockIn) public view returns (uint256 usdgOut) {
        Stock memory s = _tradable(stock);
        if (stockIn == 0) revert ZeroAmount();
        usdgOut = Math.mulDiv(_stockToUsdg(s, stockIn, _price(s)), BPS - spreadBps, BPS);
        if (usdgOut > maxTradeUsdg) revert TradeTooLarge();
    }

    // ---------------------------------------------------------------- Views

    function isMarketOpen() public view returns (bool) {
        return MarketHours.isRegularSession(block.timestamp) && !isHoliday[MarketHours.newYorkDay(block.timestamp)];
    }

    /// @notice Total vault value in USDG, marking stock tokens at their Chainlink price.
    function nav() public view returns (uint256 total) {
        total = usdg.balanceOf(address(this));
        uint256 n = _stockList.length;
        for (uint256 i; i < n; ++i) {
            total += stockValue(_stockList[i]);
        }
    }

    function stockValue(address stock) public view returns (uint256) {
        Stock memory s = stocks[stock];
        if (!s.listed) revert UnknownStock();
        uint256 bal = IERC20Metadata(stock).balanceOf(address(this));
        return bal == 0 ? 0 : _stockToUsdg(s, bal, _price(s));
    }

    function exposureBps(address stock) public view returns (uint256) {
        uint256 total = nav();
        return total == 0 ? 0 : Math.mulDiv(stockValue(stock), BPS, total);
    }

    function stockList() external view returns (address[] memory) {
        return _stockList;
    }

    function decimals() public view override returns (uint8) {
        return _usdgDecimals;
    }

    // ---------------------------------------------------------------- Agent (bounded)

    function setSpread(uint256 newSpreadBps) external onlyAgentOrOwner {
        _setSpread(newSpreadBps);
    }

    function pauseDesk() external onlyAgentOrOwner {
        deskPaused = true;
        emit DeskPaused(msg.sender);
    }

    // ---------------------------------------------------------------- Owner (no fund access)

    function listStock(address stock, AggregatorV3Interface feed, uint256 maxExposureBps_) external onlyOwner {
        if (stock == address(0) || address(feed) == address(0) || stock == address(usdg)) revert InvalidAddress();
        if (stocks[stock].listed) revert AlreadyListed();
        if (_stockList.length >= MAX_STOCKS) revert TooManyStocks();
        if (maxExposureBps_ == 0 || maxExposureBps_ > MAX_EXPOSURE_BPS) revert BadExposure();
        stocks[stock] = Stock({
            feed: feed,
            maxExposureBps: uint16(maxExposureBps_),
            tokenDecimals: IERC20Metadata(stock).decimals(),
            feedDecimals: feed.decimals(),
            listed: true,
            enabled: true
        });
        _stockList.push(stock);
        emit StockListed(stock, address(feed), maxExposureBps_);
    }

    function updateStock(address stock, bool enabled, uint256 maxExposureBps_) external onlyOwner {
        if (!stocks[stock].listed) revert UnknownStock();
        if (maxExposureBps_ == 0 || maxExposureBps_ > MAX_EXPOSURE_BPS) revert BadExposure();
        stocks[stock].enabled = enabled;
        stocks[stock].maxExposureBps = uint16(maxExposureBps_);
        emit StockUpdated(stock, enabled, maxExposureBps_);
    }

    function setAgent(address newAgent) external onlyOwner {
        _setAgent(newAgent);
    }

    function setMaxTrade(uint256 newMax) external onlyOwner {
        _setMaxTrade(newMax);
    }

    function setHoliday(uint256 newYorkDay, bool closed) external onlyOwner {
        isHoliday[newYorkDay] = closed;
        emit HolidaySet(newYorkDay, closed);
    }

    function unpauseDesk() external onlyOwner {
        deskPaused = false;
        emit DeskUnpaused();
    }

    // ---------------------------------------------------------------- Internals

    /// @dev Freshly minted shares are locked so nobody can deposit and instantly withdraw a stock basket at oracle price.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && block.timestamp < unlockAt[from]) revert SharesLocked(unlockAt[from]);
        super._update(from, to, value);
    }

    function _tradable(address stock) private view returns (Stock memory s) {
        s = stocks[stock];
        if (!s.listed) revert UnknownStock();
        if (!s.enabled) revert StockDisabled();
    }

    function _price(Stock memory s) private view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = s.feed.latestRoundData();
        if (answer <= 0 || updatedAt == 0 || block.timestamp - updatedAt > MAX_PRICE_AGE) revert StalePrice();
        return uint256(answer);
    }

    /// @dev Assumes 1 USDG = 1 USD, which is how Robinhood Chain stock feeds are quoted.
    function _stockToUsdg(Stock memory s, uint256 amount, uint256 price) private view returns (uint256) {
        return Math.mulDiv(amount * price, 10 ** _usdgDecimals, 10 ** (uint256(s.tokenDecimals) + s.feedDecimals));
    }

    function _usdgToStock(Stock memory s, uint256 usdgAmount, uint256 price) private view returns (uint256) {
        return Math.mulDiv(usdgAmount, 10 ** (uint256(s.tokenDecimals) + s.feedDecimals), price * 10 ** _usdgDecimals);
    }

    function _setSpread(uint256 newSpreadBps) private {
        if (newSpreadBps < MIN_SPREAD_BPS || newSpreadBps > MAX_SPREAD_BPS) revert BadSpread();
        spreadBps = newSpreadBps;
        emit SpreadSet(newSpreadBps);
    }

    function _setAgent(address newAgent) private {
        if (newAgent == address(0)) revert InvalidAddress();
        agent = newAgent;
        emit AgentSet(newAgent);
    }

    function _setMaxTrade(uint256 newMax) private {
        if (newMax == 0) revert ZeroAmount();
        maxTradeUsdg = newMax;
        emit MaxTradeSet(newMax);
    }
}
