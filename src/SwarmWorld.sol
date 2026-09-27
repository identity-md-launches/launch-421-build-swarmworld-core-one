// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title SwarmWorld Core
/// @notice A persistent on-chain world where independent workers submit, test, review and verify
///         missions before world state changes. No owner, no admin, no token, no upgradeability,
///         no pausing, no external contracts. Native ETH escrowed per mission is the only value.
/// @dev Seat IDs are recorded for provenance only. The contract does not authenticate them and
///      makes no claim about who operates a seat; the four payout addresses are the authorisation.
contract SwarmWorld {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    enum MissionState {
        OPEN, // awaiting the builder's outcome
        WORKING, // outcome submitted, awaiting tester then reviewer
        VERIFYING, // test and review passed, awaiting verifier
        PASSED, // verified, awaiting permissionless settlement
        FAILED, // a stage reported failure; sponsor refunded
        SETTLED, // world state applied; workers paid
        EXPIRED // lifetime elapsed before PASSED; sponsor refunded
    }

    enum MissionType {
        ENERGY_REPAIR
    }

    struct Settlement {
        uint16 energy; // 0..1000
        uint16 food; // 0..1000
        uint16 materials; // 0..1000
        uint16 knowledge; // 0..1000
        uint32 population;
        uint8 stability; // 0..100
        uint256 activeMission; // 0 when none
    }

    /// @notice The four payout addresses and the four IMD seat IDs recorded at mission creation.
    struct Roles {
        address builder;
        address tester;
        address reviewer;
        address verifier;
        uint32 builderSeat;
        uint32 testerSeat;
        uint32 reviewerSeat;
        uint32 verifierSeat;
    }

    struct Mission {
        uint8 settlementId;
        MissionType missionType;
        MissionState state;
        address sponsor;
        uint64 createdAt;
        uint64 deadline;
        uint256 reward;
        Roles roles;
        bool testPassed; // tester reported pass (reviewer may proceed)
        uint16 energyGain;
        uint16 materialsCost;
        bytes32 builderArtifactHash;
        bytes32 testHash;
        bytes32 reviewHash;
        bytes32 verificationHash;
        bytes32 worldStateBefore;
        bytes32 proofHash;
    }

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    uint8 public constant SETTLEMENT_COUNT = 3;
    uint16 public constant RESOURCE_MAX = 1000;
    uint8 public constant STABILITY_MAX = 100;
    uint16 public constant TICK_ENERGY_DECAY = 25;
    uint16 public constant ENERGY_CRISIS_THRESHOLD = 300;
    uint256 public constant TICK_INTERVAL = 1 days;
    uint256 public constant MISSION_LIFETIME = 3 days;
    uint16 public constant MIN_ENERGY_GAIN = 200;
    uint16 public constant MAX_ENERGY_GAIN = 300;
    uint16 public constant MAX_MATERIALS_COST = 100;
    uint256 public constant BUILDER_SHARE_BPS = 5000;
    uint256 public constant TESTER_SHARE_BPS = 1500;
    uint256 public constant REVIEWER_SHARE_BPS = 1500;
    uint256 public constant BPS = 10_000;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    Settlement[SETTLEMENT_COUNT] private _settlements;
    mapping(uint256 => Mission) private _missions;

    /// @notice Next mission ID. Mission IDs start at 1 so 0 can mean "no mission".
    uint256 public nextMissionId = 1;
    /// @notice Timestamp of the last accepted tick (deployment time initially).
    uint256 public lastTickAt;
    /// @notice Number of ticks executed since deployment.
    uint256 public tickCount;
    /// @notice ETH withdrawable by each address through claim().
    mapping(address => uint256) public claimable;
    /// @notice Sum of every claimable balance. Together with escrowed rewards it equals the balance.
    uint256 public totalClaimable;
    /// @notice Sum of rewards escrowed in missions that have not reached a terminal state.
    uint256 public totalEscrowed;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event Tick(uint256 indexed tickNumber, uint256 timestamp);
    event EnergyCrisis(uint8 indexed settlementId, uint16 energy);
    event MissionOpened(
        uint256 indexed missionId,
        uint8 indexed settlementId,
        address indexed sponsor,
        uint256 reward,
        uint64 deadline,
        Roles roles
    );
    event OutcomeSubmitted(
        uint256 indexed missionId, uint16 energyGain, uint16 materialsCost, bytes32 builderArtifactHash
    );
    event TestSubmitted(uint256 indexed missionId, bytes32 testHash, bool pass);
    event ReviewSubmitted(uint256 indexed missionId, bytes32 reviewHash, bool pass);
    event OutcomeVerified(uint256 indexed missionId, bytes32 verificationHash, bool pass);
    event MissionPassed(uint256 indexed missionId);
    event MissionFailed(uint256 indexed missionId, MissionState failedAtState, uint256 refund);
    event MissionExpired(uint256 indexed missionId, uint256 refund);
    event MissionSettled(
        uint256 indexed missionId,
        uint8 indexed settlementId,
        bytes32 proofHash,
        bytes32 worldStateBefore,
        bytes32 worldStateAfter,
        uint16 energyBefore,
        uint16 energyAfter,
        uint16 materialsBefore,
        uint16 materialsAfter
    );
    event RewardCredited(uint256 indexed missionId, address indexed account, uint256 amount);
    event Claimed(address indexed account, uint256 amount);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error TickTooEarly(uint256 nextTickAt);
    error InvalidSettlement(uint8 settlementId);
    error SettlementBusy(uint8 settlementId, uint256 activeMission);
    error EnergyNotInCrisis(uint16 energy);
    error ZeroReward();
    error ZeroRoleAddress();
    error RolesNotDistinct();
    error SeatsNotDistinct();
    error UnknownMission(uint256 missionId);
    error WrongState(uint256 missionId, MissionState actual, MissionState expected);
    error NotRole(uint256 missionId, address expected, address actual);
    error NotSponsor(uint256 missionId, address expected, address actual);
    error MissionDeadlinePassed(uint256 missionId, uint64 deadline);
    error MissionNotExpired(uint256 missionId, uint64 deadline);
    error EnergyGainOutOfRange(uint16 energyGain);
    error MaterialsCostTooHigh(uint16 materialsCost);
    error EnergyWouldExceedMax(uint16 resulting);
    error InsufficientMaterials(uint16 available, uint16 required);
    error NothingToClaim(address account);
    error EthTransferFailed(address to, uint256 amount);

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    constructor() {
        _settlements[0] = Settlement({
            energy: 500, food: 500, materials: 500, knowledge: 500, population: 100, stability: 80, activeMission: 0
        });
        _settlements[1] = Settlement({
            energy: 420, food: 550, materials: 700, knowledge: 350, population: 100, stability: 75, activeMission: 0
        });
        _settlements[2] = Settlement({
            energy: 120, food: 420, materials: 300, knowledge: 180, population: 100, stability: 75, activeMission: 0
        });
        lastTickAt = block.timestamp;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Full state of a settlement.
    function getSettlement(uint8 settlementId) external view returns (Settlement memory) {
        _requireSettlement(settlementId);
        return _settlements[settlementId];
    }

    /// @notice Human-readable settlement name (not stored on chain; pure mapping of the fixed IDs).
    function settlementName(uint8 settlementId) external pure returns (string memory) {
        _requireSettlement(settlementId);
        if (settlementId == 0) return "Genesis City";
        if (settlementId == 1) return "Iron Valley";
        return "Nova Port";
    }

    /// @notice Full record of a mission. Reverts for IDs that were never opened.
    function getMission(uint256 missionId) external view returns (Mission memory) {
        _requireMission(missionId);
        return _missions[missionId];
    }

    /// @notice Deterministic hash of the whole world (all settlements, all fields except the
    ///         active-mission pointer). Used as `worldStateBefore` in the proof hash.
    function worldStateHash() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                _packSettlement(_settlements[0]), _packSettlement(_settlements[1]), _packSettlement(_settlements[2])
            )
        );
    }

    /// @notice Timestamp at which the next tick becomes callable.
    function nextTickAt() public view returns (uint256) {
        return lastTickAt + TICK_INTERVAL;
    }

    /// @notice Recomputes the proof hash for a mission from its stored fields. Pure function of
    ///         the inputs, so anyone can reproduce the value emitted at settlement.
    function computeProofHash(
        uint256 missionId,
        uint8 settlementId,
        bytes32 worldStateBefore,
        uint16 energyGain,
        uint16 materialsCost,
        bytes32 builderArtifactHash,
        bytes32 testHash,
        bytes32 reviewHash,
        bytes32 verificationHash,
        uint32[4] memory seatIds
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                missionId,
                settlementId,
                worldStateBefore,
                energyGain,
                materialsCost,
                builderArtifactHash,
                testHash,
                reviewHash,
                verificationHash,
                seatIds[0],
                seatIds[1],
                seatIds[2],
                seatIds[3]
            )
        );
    }

    // ---------------------------------------------------------------------
    // Time
    // ---------------------------------------------------------------------

    /// @notice Permissionless daily tick. Reduces energy by 25 (saturating at zero) for every
    ///         settlement without an active mission and reports settlements in energy crisis.
    function tick() external {
        uint256 due = lastTickAt + TICK_INTERVAL;
        if (block.timestamp < due) revert TickTooEarly(due);
        lastTickAt = block.timestamp;
        uint256 n = ++tickCount;
        emit Tick(n, block.timestamp);

        for (uint8 i = 0; i < SETTLEMENT_COUNT; ++i) {
            Settlement storage s = _settlements[i];
            if (s.activeMission == 0) {
                s.energy = s.energy > TICK_ENERGY_DECAY ? s.energy - TICK_ENERGY_DECAY : 0;
            }
            if (s.energy < ENERGY_CRISIS_THRESHOLD) emit EnergyCrisis(i, s.energy);
        }
    }

    // ---------------------------------------------------------------------
    // Missions
    // ---------------------------------------------------------------------

    /// @notice Open an ENERGY_REPAIR mission for a settlement in energy crisis. msg.value is the
    ///         reward, escrowed until the mission reaches a terminal state.
    /// @param settlementId Settlement in crisis (energy < 300) with no active mission.
    /// @param roles Four distinct nonzero payout addresses and four distinct seat IDs.
    function openEnergyMission(uint8 settlementId, Roles calldata roles) external payable returns (uint256 missionId) {
        _requireSettlement(settlementId);
        Settlement storage s = _settlements[settlementId];
        if (s.activeMission != 0) revert SettlementBusy(settlementId, s.activeMission);
        if (s.energy >= ENERGY_CRISIS_THRESHOLD) revert EnergyNotInCrisis(s.energy);
        if (msg.value == 0) revert ZeroReward();
        _validateRoles(roles);

        missionId = nextMissionId++;
        Mission storage m = _missions[missionId];
        m.settlementId = settlementId;
        m.missionType = MissionType.ENERGY_REPAIR;
        m.state = MissionState.OPEN;
        m.sponsor = msg.sender;
        m.createdAt = uint64(block.timestamp);
        m.deadline = uint64(block.timestamp + MISSION_LIFETIME);
        m.reward = msg.value;
        m.roles = roles;

        s.activeMission = missionId;
        totalEscrowed += msg.value;

        emit MissionOpened(missionId, settlementId, msg.sender, msg.value, m.deadline, roles);
    }

    /// @notice Builder proposes the outcome. Moves OPEN -> WORKING.
    function submitOutcome(uint256 missionId, uint16 energyGain, uint16 materialsCost, bytes32 builderArtifactHash)
        external
    {
        Mission storage m = _live(missionId, MissionState.OPEN);
        if (msg.sender != m.roles.builder) revert NotRole(missionId, m.roles.builder, msg.sender);
        _validateOutcome(_settlements[m.settlementId], energyGain, materialsCost);

        m.energyGain = energyGain;
        m.materialsCost = materialsCost;
        m.builderArtifactHash = builderArtifactHash;
        m.state = MissionState.WORKING;
        emit OutcomeSubmitted(missionId, energyGain, materialsCost, builderArtifactHash);
    }

    /// @notice Tester reports. Stays WORKING on pass (reviewer is next); FAILED on fail.
    function submitTest(uint256 missionId, bytes32 testHash, bool pass) external {
        Mission storage m = _live(missionId, MissionState.WORKING);
        if (msg.sender != m.roles.tester) revert NotRole(missionId, m.roles.tester, msg.sender);
        if (m.testPassed) revert WrongState(missionId, m.state, MissionState.VERIFYING);

        m.testHash = testHash;
        emit TestSubmitted(missionId, testHash, pass);
        if (pass) {
            m.testPassed = true;
        } else {
            _fail(missionId, m);
        }
    }

    /// @notice Reviewer reports after a passing test. WORKING -> VERIFYING on pass; FAILED on fail.
    function submitReview(uint256 missionId, bytes32 reviewHash, bool pass) external {
        Mission storage m = _live(missionId, MissionState.WORKING);
        if (msg.sender != m.roles.reviewer) revert NotRole(missionId, m.roles.reviewer, msg.sender);
        if (!m.testPassed) revert WrongState(missionId, m.state, MissionState.WORKING);

        m.reviewHash = reviewHash;
        emit ReviewSubmitted(missionId, reviewHash, pass);
        if (pass) {
            m.state = MissionState.VERIFYING;
        } else {
            _fail(missionId, m);
        }
    }

    /// @notice Verifier reports. VERIFYING -> PASSED on pass; FAILED on fail.
    function verifyOutcome(uint256 missionId, bytes32 verificationHash, bool pass) external {
        Mission storage m = _live(missionId, MissionState.VERIFYING);
        if (msg.sender != m.roles.verifier) revert NotRole(missionId, m.roles.verifier, msg.sender);

        m.verificationHash = verificationHash;
        emit OutcomeVerified(missionId, verificationHash, pass);
        if (pass) {
            m.state = MissionState.PASSED;
            emit MissionPassed(missionId);
        } else {
            _fail(missionId, m);
        }
    }

    /// @notice Permissionless settlement of a PASSED mission: applies the outcome to the world,
    ///         stores the proof hash and credits the four workers.
    function settleMission(uint256 missionId) external {
        Mission storage m = _mission(missionId);
        if (m.state != MissionState.PASSED) revert WrongState(missionId, m.state, MissionState.PASSED);

        Settlement storage s = _settlements[m.settlementId];
        // Re-check the outcome against the current world. Energy and materials of a settlement
        // with an active mission cannot move, so this holds by construction; it is kept as a
        // defensive invariant so the bounds can never be violated by a future code path.
        _validateOutcome(s, m.energyGain, m.materialsCost);

        bytes32 before = worldStateHash();
        uint16 energyBefore = s.energy;
        uint16 materialsBefore = s.materials;

        s.energy = energyBefore + m.energyGain;
        s.materials = materialsBefore - m.materialsCost;
        s.activeMission = 0;
        m.state = MissionState.SETTLED;
        m.worldStateBefore = before;

        bytes32 proof = _proofFor(missionId, m);
        m.proofHash = proof;

        _payWorkers(missionId, m);

        emit MissionSettled(
            missionId,
            m.settlementId,
            proof,
            before,
            worldStateHash(),
            energyBefore,
            s.energy,
            materialsBefore,
            s.materials
        );
    }

    /// @notice Sponsor expires a mission whose lifetime elapsed before it PASSED and reclaims the
    ///         reward (credited to `claimable`, withdrawn through claim()).
    function expireMission(uint256 missionId) external {
        Mission storage m = _mission(missionId);
        if (msg.sender != m.sponsor) revert NotSponsor(missionId, m.sponsor, msg.sender);
        MissionState st = m.state;
        if (st != MissionState.OPEN && st != MissionState.WORKING && st != MissionState.VERIFYING) {
            revert WrongState(missionId, st, MissionState.OPEN);
        }
        if (block.timestamp < m.deadline) revert MissionNotExpired(missionId, m.deadline);

        m.state = MissionState.EXPIRED;
        _settlements[m.settlementId].activeMission = 0;
        uint256 refund = _releaseToSponsor(missionId, m);
        emit MissionExpired(missionId, refund);
    }

    // ---------------------------------------------------------------------
    // Rewards
    // ---------------------------------------------------------------------

    /// @notice Withdraw every ETH credited to the caller. Balance is zeroed before the transfer.
    function claim() external {
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToClaim(msg.sender);
        claimable[msg.sender] = 0;
        totalClaimable -= amount;
        emit Claimed(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert EthTransferFailed(msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _requireSettlement(uint8 settlementId) private pure {
        if (settlementId >= SETTLEMENT_COUNT) revert InvalidSettlement(settlementId);
    }

    function _requireMission(uint256 missionId) private view {
        if (missionId == 0 || missionId >= nextMissionId) revert UnknownMission(missionId);
    }

    function _mission(uint256 missionId) private view returns (Mission storage m) {
        _requireMission(missionId);
        m = _missions[missionId];
    }

    /// @dev Loads a mission that must be in `expected` state and still within its lifetime.
    function _live(uint256 missionId, MissionState expected) private view returns (Mission storage m) {
        m = _mission(missionId);
        if (m.state != expected) revert WrongState(missionId, m.state, expected);
        if (block.timestamp >= m.deadline) revert MissionDeadlinePassed(missionId, m.deadline);
    }

    function _validateRoles(Roles calldata r) private pure {
        if (r.builder == address(0) || r.tester == address(0) || r.reviewer == address(0) || r.verifier == address(0)) {
            revert ZeroRoleAddress();
        }
        if (
            r.builder == r.tester || r.builder == r.reviewer || r.builder == r.verifier || r.tester == r.reviewer
                || r.tester == r.verifier || r.reviewer == r.verifier
        ) revert RolesNotDistinct();
        if (
            r.builderSeat == r.testerSeat || r.builderSeat == r.reviewerSeat || r.builderSeat == r.verifierSeat
                || r.testerSeat == r.reviewerSeat || r.testerSeat == r.verifierSeat || r.reviewerSeat == r.verifierSeat
        ) revert SeatsNotDistinct();
    }

    function _validateOutcome(Settlement storage s, uint16 energyGain, uint16 materialsCost) private view {
        if (energyGain < MIN_ENERGY_GAIN || energyGain > MAX_ENERGY_GAIN) revert EnergyGainOutOfRange(energyGain);
        if (materialsCost > MAX_MATERIALS_COST) revert MaterialsCostTooHigh(materialsCost);
        uint16 resulting = s.energy + energyGain; // both <= 1000, no overflow in uint16 range
        if (resulting > RESOURCE_MAX) revert EnergyWouldExceedMax(resulting);
        if (s.materials < materialsCost) revert InsufficientMaterials(s.materials, materialsCost);
    }

    function _fail(uint256 missionId, Mission storage m) private {
        MissionState failedAt = m.state;
        m.state = MissionState.FAILED;
        _settlements[m.settlementId].activeMission = 0;
        uint256 refund = _releaseToSponsor(missionId, m);
        emit MissionFailed(missionId, failedAt, refund);
    }

    /// @dev Moves the escrowed reward of a terminal mission to the sponsor's claimable balance.
    function _releaseToSponsor(uint256 missionId, Mission storage m) private returns (uint256 refund) {
        refund = m.reward;
        totalEscrowed -= refund;
        _credit(missionId, m.sponsor, refund);
    }

    function _payWorkers(uint256 missionId, Mission storage m) private {
        uint256 reward = m.reward;
        totalEscrowed -= reward;
        uint256 builderShare = reward * BUILDER_SHARE_BPS / BPS;
        uint256 testerShare = reward * TESTER_SHARE_BPS / BPS;
        uint256 reviewerShare = reward * REVIEWER_SHARE_BPS / BPS;
        uint256 verifierShare = reward - builderShare - testerShare - reviewerShare;
        _credit(missionId, m.roles.builder, builderShare);
        _credit(missionId, m.roles.tester, testerShare);
        _credit(missionId, m.roles.reviewer, reviewerShare);
        _credit(missionId, m.roles.verifier, verifierShare);
    }

    function _credit(uint256 missionId, address account, uint256 amount) private {
        if (amount == 0) return;
        claimable[account] += amount;
        totalClaimable += amount;
        emit RewardCredited(missionId, account, amount);
    }

    function _proofFor(uint256 missionId, Mission storage m) private view returns (bytes32) {
        return computeProofHash(
            missionId,
            m.settlementId,
            m.worldStateBefore,
            m.energyGain,
            m.materialsCost,
            m.builderArtifactHash,
            m.testHash,
            m.reviewHash,
            m.verificationHash,
            [m.roles.builderSeat, m.roles.testerSeat, m.roles.reviewerSeat, m.roles.verifierSeat]
        );
    }

    function _packSettlement(Settlement storage s) private view returns (bytes32) {
        return keccak256(abi.encode(s.energy, s.food, s.materials, s.knowledge, s.population, s.stability));
    }
}
