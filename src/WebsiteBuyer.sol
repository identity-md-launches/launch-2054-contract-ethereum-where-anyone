// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IIntake} from "./interfaces/IIntake.sol";
import {IntakeAccount} from "./IntakeAccount.sol";
import {JsonText} from "./libraries/JsonText.sol";

interface IWrappedNative {
    function deposit() external payable;
}

/// @title Buy a hosted website with ETH through Uniswap v4 and IdentityMD Intake v2
/// @notice Each caller owns a distinct payer account. Excess IMD remains here; no funds wait on callbacks.
contract WebsiteBuyer is Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    uint256 public constant MIN_IMD_OUT = 0.5 ether;
    uint256 public constant MAX_TEXT_BYTES = 2000;
    uint256 public constant MAX_RESULT_URI_BYTES = 192;
    /// @notice Bounds keep the largest body (8192 + 2000 + 7 * 42 bytes) under Intake's 16 KiB limit.
    uint256 public constant MAX_TEMPLATE_BYTES = 8192;
    uint256 public constant MAX_TEMPLATE_SLOTS = 8;

    enum State {
        None,
        Pending,
        Done,
        Failed
    }

    /// @notice What fills a template slot: the caller's words, or the caller's address in lowercase hex.
    enum Slot {
        Words,
        Caller
    }

    /// @notice The owner's JSON with gaps: parts[0] ++ fill(slots[0]) ++ parts[1] ++ ... ++ parts[n].
    struct Template {
        bytes[] parts;
        Slot[] slots;
        bool enabled;
    }

    struct Purchase {
        uint256 templateId;
        uint256 minImdOut;
        uint256 maxIntakePrice;
        uint256 deadline;
        uint256 configurationVersion;
    }

    struct Request {
        address user;
        State state;
        uint8 failureStatus;
        address asset;
        uint256 imdPaid;
        bytes32 bodyHash;
        bytes32 resultHash;
        bytes32 failureReason;
        string uri;
    }

    error InvalidAddress();
    error InvalidPrice();
    error InvalidPool();
    error PoolNotConfigured();
    error DependencyHasNoCode(address dependency);
    error UnsupportedDecimals();
    error UnknownTemplate(uint256 id);
    error InvalidTemplate();
    error InvalidFloor();
    error InvalidAction();
    error Paused();
    error Expired();
    error ConfigurationChanged();
    error IncorrectETH(uint256 expected, uint256 received);
    error ActionNotSold();
    error IntakePriceExceeded(uint256 price, uint256 maximum);
    error InsufficientOutput(uint256 received, uint256 minimum);
    error IncompleteSwap();
    error UnexpectedCallback();
    error IncorrectTokenMovement();
    error DuplicateRequest();
    error NotPending();
    error InvalidFailureStatus();

    event ConfigurationChangedTo(uint256 indexed version);
    event ETHPriceSet(uint256 price);
    event IMDFloorSet(uint256 floor);
    event IntakeSet(address indexed intake);
    event IMDSet(address indexed imd);
    event ActionSet(bytes32 indexed action);
    event TemplateSet(uint256 indexed id, bytes[] parts, Slot[] slots, bool enabled);
    event PoolSet(address indexed manager, address indexed inputCurrency, bytes32 indexed poolId, bytes hookData);
    event PoolDisabled();
    event PauseSet(bool paused);
    event AccountOpened(address indexed user, address account);
    event WebsiteRequested(
        bytes32 indexed requestId,
        address indexed user,
        address indexed intake,
        address account,
        uint256 templateId,
        bytes32 bodyHash,
        uint256 ethPaid,
        uint256 imdBought,
        uint256 imdPaid
    );
    event WebsiteResult(
        bytes32 indexed requestId, address indexed user, address indexed intake, bytes32 resultHash, string uri
    );
    event WebsiteFailed(
        bytes32 indexed requestId, address indexed user, address indexed intake, uint8 status, bytes32 reason
    );

    uint256 public ethPrice = 0.003 ether;
    /// @notice Owner's minimum fresh IMD per purchase, never below MIN_IMD_OUT. Protects the retained surplus.
    uint256 public imdFloor = MIN_IMD_OUT;
    uint256 public configurationVersion = 1;
    IIntake public intake;
    address public imd;
    bytes32 public action = bytes32("job.open@job-1");
    bool public paused;
    bool public poolConfigured;
    IPoolManager public poolManager;
    /// @notice Zero is Uniswap's native ETH currency; otherwise a WETH-compatible wrapper.
    address public inputCurrency;
    PoolKey public poolKey;
    bytes public hookData;
    mapping(uint256 => Template) private _templates;
    mapping(address => IntakeAccount) public accountOf;
    // Namespaced by originating Intake, so migrations cannot collide or hijack an old request ID.
    mapping(address => mapping(bytes32 => Request)) private _requests;
    bytes32 private _swapCommitment;
    uint256 private _swapPhase;

    /// @dev No external calls or code checks: this also deploys on the factory's empty rehearsal chain.
    constructor(address owner_, IIntake intake_, address imd_) Ownable(owner_) {
        if (address(intake_) == address(0) || imd_ == address(0)) revert InvalidAddress();
        intake = intake_;
        imd = imd_;
        // The brief's body with the caller as owner. Owner-settable, so the key set can change without a redeploy.
        bytes[] memory parts = new bytes[](3);
        parts[0] = '{"objective":"Build a one-page website: ';
        parts[1] = '","skill":"build-website","host":true,"owner":"';
        parts[2] = '"}';
        Slot[] memory slots = new Slot[](2);
        slots[0] = Slot.Words;
        slots[1] = Slot.Caller;
        _storeTemplate(0, parts, slots, true);
        emit IntakeSet(address(intake_));
        emit IMDSet(imd_);
        emit ETHPriceSet(ethPrice);
        emit IMDFloorSet(MIN_IMD_OUT);
        emit ActionSet(action);
    }

    /// @notice Spend exactly ethPrice, receiving fresh IMD, and buy one job for msg.sender.
    /// @dev The caller's version binds the template, route, token, action, Intake and ETH price they reviewed.
    function buyWebsite(string calldata words, Purchase calldata purchase)
        external
        payable
        nonReentrant
        returns (bytes32 requestId)
    {
        if (paused) revert Paused();
        if (block.timestamp > purchase.deadline) revert Expired();
        if (purchase.configurationVersion != configurationVersion) revert ConfigurationChanged();
        if (msg.value != ethPrice) revert IncorrectETH(ethPrice, msg.value);
        if (!poolConfigured) revert PoolNotConfigured();
        _requireCode(address(intake));
        _requireCode(imd);
        _requireCode(address(poolManager));
        if (IERC20Metadata(imd).decimals() != 18) revert UnsupportedDecimals();

        bytes memory body = bodyOf(purchase.templateId, msg.sender, words);
        uint256 price = intake.priceOf(action, imd);
        if (price == 0) revert ActionNotSold();
        if (price > purchase.maxIntakePrice) revert IntakePriceExceeded(price, purchase.maxIntakePrice);
        // The buyer has no stake in the surplus, so the owner's floor bounds what a sandwich can take from it.
        uint256 minimum = purchase.minImdOut;
        if (minimum < imdFloor) minimum = imdFloor;
        if (minimum < price) minimum = price;
        uint256 bought = _buyIMD(minimum);
        requestId = _open(body, purchase.templateId, price, bought);
    }

    function _open(bytes memory body, uint256 templateId, uint256 price, uint256 bought)
        private
        returns (bytes32 requestId)
    {
        IntakeAccount account = accountOf[msg.sender];
        if (address(account) == address(0)) {
            account = new IntakeAccount{salt: bytes32(uint256(uint160(msg.sender)))}(msg.sender);
            accountOf[msg.sender] = account;
            emit AccountOpened(msg.sender, address(account));
        }
        IERC20 token = IERC20(imd);
        uint256 beforeHub = token.balanceOf(address(this));
        uint256 beforeAccount = token.balanceOf(address(account));
        token.safeTransfer(address(account), price);
        if (token.balanceOf(address(account)) != beforeAccount + price) revert IncorrectTokenMovement();
        requestId = account.ask(
            intake,
            action,
            body,
            IIntake.Callback(address(this), this.onIntakeResult.selector),
            this.onIntakeFailure.selector,
            imd,
            price
        );
        if (token.balanceOf(address(this)) != beforeHub - price) revert IncorrectTokenMovement();
        Request storage r = _requests[address(intake)][requestId];
        if (requestId == bytes32(0) || r.state != State.None) revert DuplicateRequest();
        r.user = msg.sender;
        r.state = State.Pending;
        r.asset = imd;
        r.imdPaid = price;
        r.bodyHash = keccak256(body);
        emit WebsiteRequested(
            requestId, msg.sender, address(intake), address(account), templateId, r.bodyHash, msg.value, bought, price
        );
    }

    function _buyIMD(uint256 minimum) private returns (uint256 received) {
        uint256 beforeBalance = IERC20(imd).balanceOf(address(this));
        if (inputCurrency != address(0)) {
            _requireCode(inputCurrency);
            uint256 beforeWrapped = IERC20(inputCurrency).balanceOf(address(this));
            IWrappedNative(inputCurrency).deposit{value: msg.value}();
            if (IERC20(inputCurrency).balanceOf(address(this)) != beforeWrapped + msg.value) {
                revert IncorrectTokenMovement();
            }
        }
        bytes memory data = abi.encode(msg.value, minimum);
        _swapCommitment = keccak256(data);
        _swapPhase = 1;
        bytes memory result = poolManager.unlock(data);
        if (_swapPhase != 2) revert UnexpectedCallback();
        delete _swapCommitment;
        delete _swapPhase;
        uint256 afterBalance = IERC20(imd).balanceOf(address(this));
        if (afterBalance < beforeBalance) revert IncorrectTokenMovement();
        received = afterBalance - beforeBalance;
        if (received != abi.decode(result, (uint256))) revert IncorrectTokenMovement();
        if (received < minimum) revert InsufficientOutput(received, minimum);
    }

    /// @dev Only the configured manager, once, during our own committed unlock. Never a free-standing swap entry.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || _swapPhase != 1 || keccak256(data) != _swapCommitment) {
            revert UnexpectedCallback();
        }
        _swapPhase = 2;
        (uint256 amountIn, uint256 minimum) = abi.decode(data, (uint256, uint256));
        PoolKey memory key = poolKey;
        bool zeroForOne = Currency.unwrap(key.currency0) == inputCurrency;
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            hookData
        );
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        // Do not silently retain unspent ETH or allow hooks to spend any pre-existing balances.
        if (int256(inputDelta) != -int256(amountIn) || outputDelta <= 0) revert IncompleteSwap();
        uint256 output = uint256(uint128(outputDelta));
        if (output < minimum) revert InsufficientOutput(output, minimum);
        // Sync native currency too: a hook may have synced an ERC-20 earlier in this unlock.
        poolManager.sync(Currency.wrap(inputCurrency));
        uint256 settled;
        if (inputCurrency == address(0)) {
            settled = poolManager.settle{value: amountIn}();
        } else {
            IERC20(inputCurrency).safeTransfer(address(poolManager), amountIn);
            settled = poolManager.settle();
        }
        if (settled != amountIn) revert IncorrectTokenMovement();
        poolManager.take(Currency.wrap(imd), address(this), output);
        return abi.encode(output);
    }

    /// @notice Exact request bytes for `user`, with Caller slots as lowercase hex; preview before payment.
    function bodyOf(uint256 id, address user, string calldata words) public view returns (bytes memory body) {
        if (user == address(0)) revert InvalidAddress();
        Template storage t = _templates[id];
        if (!t.enabled) revert UnknownTemplate(id);
        JsonText.check(bytes(words), MAX_TEXT_BYTES, false);
        body = t.parts[0];
        for (uint256 i; i < t.slots.length; ++i) {
            bytes memory fill = t.slots[i] == Slot.Caller ? bytes(Strings.toHexString(user)) : bytes(words);
            body = bytes.concat(body, fill, t.parts[i + 1]);
        }
    }

    function templateOf(uint256 id) external view returns (Template memory) {
        return _templates[id];
    }

    function requestOf(address sourceIntake, bytes32 requestId) external view returns (Request memory) {
        return _requests[sourceIntake][requestId];
    }

    /// @notice Unsigned Intake result. Store and emit only; no value is released by a callback.
    /// @dev A URI over MAX_RESULT_URI_BYTES is not stored, to fit the 200,000 gas stipend, but is emitted in full.
    function onIntakeResult(bytes32 requestId, bytes32 resultHash, string calldata uri) external nonReentrant {
        Request storage r = _pending(requestId);
        r.state = State.Done;
        r.resultHash = resultHash;
        if (bytes(uri).length <= MAX_RESULT_URI_BYTES) r.uri = uri;
        emit WebsiteResult(requestId, r.user, msg.sender, resultHash, uri);
    }

    function onIntakeFailure(bytes32 requestId, uint8 status, bytes32 reason, uint16, uint16, bytes calldata)
        external
        nonReentrant
    {
        Request storage r = _pending(requestId);
        if (status != 1 && status != 2) revert InvalidFailureStatus();
        r.state = State.Failed;
        r.failureStatus = status;
        r.failureReason = reason;
        emit WebsiteFailed(requestId, r.user, msg.sender, status, reason);
    }

    function _pending(bytes32 requestId) private view returns (Request storage r) {
        r = _requests[msg.sender][requestId];
        if (r.state != State.Pending) revert NotPending();
    }

    function setETHPrice(uint256 price) external onlyOwner nonReentrant {
        if (price == 0 || price > uint256(uint128(type(int128).max))) revert InvalidPrice();
        ethPrice = price;
        emit ETHPriceSet(price);
        _changed();
    }

    function setIntake(IIntake next) external onlyOwner nonReentrant {
        if (address(next) == address(0)) revert InvalidAddress();
        intake = next;
        emit IntakeSet(address(next));
        _changed();
    }

    /// @notice A new token invalidates the old route until setPool is called again. Only 18-decimal IMD is supported.
    function setIMD(address next) external onlyOwner nonReentrant {
        if (next == address(0)) revert InvalidAddress();
        imd = next;
        poolConfigured = false;
        emit IMDSet(next);
        emit PoolDisabled();
        _changed();
    }

    /// @notice Versioned, right-padded UTF-8 job.open action ID, not a hash. The owner must verify protocol compatibility.
    function setAction(bytes32 next) external onlyOwner nonReentrant {
        if (next == bytes32(0)) revert InvalidAction();
        action = next;
        emit ActionSet(next);
        _changed();
    }

    /// @notice Raise the minimum fresh IMD per purchase. Set it from a fresh quote of ethPrice on the configured
    /// pool, less the slippage the owner tolerates, and revisit it whenever the price, pool or market moves.
    function setIMDFloor(uint256 floor) external onlyOwner nonReentrant {
        if (floor < MIN_IMD_OUT) revert InvalidFloor();
        imdFloor = floor;
        emit IMDFloorSet(floor);
        _changed();
    }

    /// @notice The owner's JSON parts around exactly one Words slot and any Caller slots. Parts are not parsed:
    /// put each slot inside a JSON string and preflight sample bodies with the Intake's checker before enabling.
    function setTemplate(uint256 id, bytes[] calldata parts, Slot[] calldata slots, bool enabled)
        external
        onlyOwner
        nonReentrant
    {
        _storeTemplate(id, parts, slots, enabled);
        _changed();
    }

    function _storeTemplate(uint256 id, bytes[] memory parts, Slot[] memory slots, bool enabled) private {
        if (parts.length != slots.length + 1 || slots.length > MAX_TEMPLATE_SLOTS) revert InvalidTemplate();
        uint256 words;
        for (uint256 i; i < slots.length; ++i) {
            if (slots[i] == Slot.Words) ++words;
        }
        uint256 size;
        for (uint256 i; i < parts.length; ++i) {
            size += parts[i].length;
        }
        if (words != 1 || size > MAX_TEMPLATE_BYTES) revert InvalidTemplate();
        Template storage t = _templates[id];
        delete t.parts;
        delete t.slots;
        for (uint256 i; i < parts.length; ++i) {
            t.parts.push(parts[i]);
        }
        for (uint256 i; i < slots.length; ++i) {
            t.slots.push(slots[i]);
        }
        t.enabled = enabled;
        emit TemplateSet(id, parts, slots, enabled);
    }

    /// @notice Choose an existing native ETH/IMD or wrapped ETH/IMD pool. Does not create or seed a pool.
    function setPool(
        IPoolManager manager,
        address input,
        uint24 fee,
        int24 tickSpacing,
        IHooks hooks,
        bytes calldata data
    ) external onlyOwner nonReentrant {
        if (address(manager) == address(0)) revert InvalidAddress();
        if (
            input == imd || tickSpacing <= 0 || tickSpacing > type(int16).max || (fee > 1_000_000 && fee != 0x800000)
                || data.length > 4096 || (fee == 0x800000 && address(hooks) == address(0))
        ) revert InvalidPool();
        poolManager = manager;
        inputCurrency = input;
        (address a, address b) = input < imd ? (input, imd) : (imd, input);
        poolKey = PoolKey(Currency.wrap(a), Currency.wrap(b), fee, tickSpacing, hooks);
        hookData = data;
        poolConfigured = true;
        emit PoolSet(address(manager), input, keccak256(abi.encode(poolKey)), data);
        _changed();
    }

    function setPaused(bool next) external onlyOwner nonReentrant {
        paused = next;
        emit PauseSet(next);
        _changed();
    }

    function _changed() private {
        ++configurationVersion;
        emit ConfigurationChangedTo(configurationVersion);
    }

    function _requireCode(address dependency) private view {
        if (dependency.code.length == 0) revert DependencyHasNoCode(dependency);
    }
}
