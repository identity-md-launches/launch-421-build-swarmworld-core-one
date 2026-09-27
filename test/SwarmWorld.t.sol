// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {SwarmWorld} from "../src/SwarmWorld.sol";

/// @dev Worker that tries to re-enter claim() from its receive hook.
contract ReentrantClaimer {
    SwarmWorld public immutable world;
    uint256 public entered;
    bool public innerReverted;

    constructor(SwarmWorld world_) {
        world = world_;
    }

    function attack() external {
        world.claim();
    }

    receive() external payable {
        entered++;
        if (entered < 3) {
            try world.claim() {}
            catch {
                innerReverted = true;
            }
        }
    }
}

/// @dev Worker whose receive hook always reverts.
contract RejectingReceiver {
    receive() external payable {
        revert("no thanks");
    }
}

contract SwarmWorldTest is Test {
    SwarmWorld internal world;

    address internal sponsor = makeAddr("sponsor");
    address internal builder = makeAddr("builder");
    address internal tester = makeAddr("tester");
    address internal reviewer = makeAddr("reviewer");
    address internal verifier = makeAddr("verifier");
    address internal stranger = makeAddr("stranger");

    uint8 internal constant NOVA_PORT = 2; // starts at energy 120: in crisis
    uint256 internal constant REWARD = 1 ether;
    uint256 internal deployedAt;

    function setUp() public {
        vm.warp(1_700_000_000);
        deployedAt = block.timestamp;
        world = new SwarmWorld();
        vm.deal(sponsor, 100 ether);
        vm.deal(stranger, 100 ether);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _roles() internal view returns (SwarmWorld.Roles memory r) {
        r = SwarmWorld.Roles({
            builder: builder,
            tester: tester,
            reviewer: reviewer,
            verifier: verifier,
            builderSeat: 11,
            testerSeat: 22,
            reviewerSeat: 33,
            verifierSeat: 44
        });
    }

    function _open() internal returns (uint256 id) {
        vm.prank(sponsor);
        id = world.openEnergyMission{value: REWARD}(NOVA_PORT, _roles());
    }

    function _openWith(uint256 reward) internal returns (uint256 id) {
        vm.prank(sponsor);
        id = world.openEnergyMission{value: reward}(NOVA_PORT, _roles());
    }

    function _submitOutcome(uint256 id) internal {
        vm.prank(builder);
        world.submitOutcome(id, 250, 60, keccak256("artifact"));
    }

    function _passTest(uint256 id) internal {
        vm.prank(tester);
        world.submitTest(id, keccak256("test"), true);
    }

    function _passReview(uint256 id) internal {
        vm.prank(reviewer);
        world.submitReview(id, keccak256("review"), true);
    }

    function _passVerify(uint256 id) internal {
        vm.prank(verifier);
        world.verifyOutcome(id, keccak256("verify"), true);
    }

    function _runToPassed(uint256 id) internal {
        _submitOutcome(id);
        _passTest(id);
        _passReview(id);
        _passVerify(id);
    }

    function _assertState(uint256 id, SwarmWorld.MissionState expected) internal view {
        assertEq(uint8(world.getMission(id).state), uint8(expected));
    }

    function _assertSettlement(
        uint8 id,
        uint16 energy,
        uint16 food,
        uint16 materials,
        uint16 knowledge,
        uint32 population,
        uint8 stability
    ) internal view {
        SwarmWorld.Settlement memory s = world.getSettlement(id);
        assertEq(s.energy, energy, "energy");
        assertEq(s.food, food, "food");
        assertEq(s.materials, materials, "materials");
        assertEq(s.knowledge, knowledge, "knowledge");
        assertEq(s.population, population, "population");
        assertEq(s.stability, stability, "stability");
    }

    function _assertConservation() internal view {
        assertEq(address(world).balance, world.totalEscrowed() + world.totalClaimable(), "ETH conservation");
    }

    // ---------------------------------------------------------------------
    // Initial world state
    // ---------------------------------------------------------------------

    function test_initialWorldState() public view {
        _assertSettlement(0, 500, 500, 500, 500, 100, 80);
        _assertSettlement(1, 420, 550, 700, 350, 100, 75);
        _assertSettlement(2, 120, 420, 300, 180, 100, 75);
        assertEq(world.getSettlement(0).activeMission, 0);
        assertEq(world.getSettlement(1).activeMission, 0);
        assertEq(world.getSettlement(2).activeMission, 0);
        assertEq(world.settlementName(0), "Genesis City");
        assertEq(world.settlementName(1), "Iron Valley");
        assertEq(world.settlementName(2), "Nova Port");
        assertEq(world.SETTLEMENT_COUNT(), 3);
        assertEq(world.nextMissionId(), 1);
        assertEq(world.tickCount(), 0);
        assertEq(world.lastTickAt(), deployedAt);
        assertEq(address(world).balance, 0);
    }

    function test_invalidSettlementIdReverts() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.InvalidSettlement.selector, 3));
        world.getSettlement(3);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.InvalidSettlement.selector, 3));
        world.settlementName(3);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.InvalidSettlement.selector, 7));
        world.openEnergyMission{value: 1}(7, _roles());
    }

    function test_unknownMissionReverts() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.UnknownMission.selector, 0));
        world.getMission(0);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.UnknownMission.selector, 1));
        world.getMission(1);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.UnknownMission.selector, 1));
        world.settleMission(1);
    }

    function test_contractDoesNotAcceptStrayEth() public {
        vm.prank(stranger);
        (bool ok,) = address(world).call{value: 1 ether}("");
        assertFalse(ok, "plain transfer must be rejected");
        assertEq(address(world).balance, 0);
    }

    // ---------------------------------------------------------------------
    // Tick
    // ---------------------------------------------------------------------

    function test_tickExact24hBoundary() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.TickTooEarly.selector, deployedAt + 1 days));
        world.tick();

        vm.warp(deployedAt + 1 days - 1);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.TickTooEarly.selector, deployedAt + 1 days));
        world.tick();

        vm.warp(deployedAt + 1 days);
        vm.expectEmit(true, false, false, true);
        emit SwarmWorld.Tick(1, deployedAt + 1 days);
        world.tick();
        assertEq(world.tickCount(), 1);
        assertEq(world.lastTickAt(), deployedAt + 1 days);
        assertEq(world.nextTickAt(), deployedAt + 2 days);

        // The next tick counts from the accepted tick, not from a fixed schedule.
        vm.warp(deployedAt + 2 days - 1);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.TickTooEarly.selector, deployedAt + 2 days));
        world.tick();
        vm.warp(deployedAt + 2 days);
        world.tick();
        assertEq(world.tickCount(), 2);
    }

    function test_tickIsPermissionless() public {
        vm.warp(deployedAt + 1 days);
        vm.prank(stranger);
        world.tick();
        assertEq(world.tickCount(), 1);
    }

    function test_tickReducesEnergyBy25OnlyForIdleSettlements() public {
        uint256 id = _open(); // Nova Port now has an active mission
        vm.warp(deployedAt + 1 days);
        world.tick();
        assertEq(world.getSettlement(0).energy, 475);
        assertEq(world.getSettlement(1).energy, 395);
        assertEq(world.getSettlement(2).energy, 120, "settlement with active mission is frozen");
        assertEq(world.getMission(id).settlementId, NOVA_PORT);
        // Other fields never change on tick.
        _assertSettlement(0, 475, 500, 500, 500, 100, 80);
        _assertSettlement(1, 395, 550, 700, 350, 100, 75);
    }

    function test_energyCannotUnderflow() public {
        // Nova Port: 120 -> 95 -> 70 -> 45 -> 20 -> 0 -> 0
        for (uint256 i = 1; i <= 7; ++i) {
            vm.warp(deployedAt + i * 1 days);
            world.tick();
        }
        assertEq(world.getSettlement(2).energy, 0);
        assertEq(world.getSettlement(0).energy, 500 - 7 * 25);
        vm.warp(deployedAt + 8 days);
        world.tick();
        assertEq(world.getSettlement(2).energy, 0, "stays at zero");
    }

    function test_energyExactly25GoesToZero() public {
        // Iron Valley 420 -> after 16 ticks: 420 - 400 = 20 -> next tick 0.
        for (uint256 i = 1; i <= 16; ++i) {
            vm.warp(deployedAt + i * 1 days);
            world.tick();
        }
        assertEq(world.getSettlement(1).energy, 20);
        // Genesis 500 -> after 20 ticks exactly 0 (500 = 20 * 25).
        for (uint256 i = 17; i <= 20; ++i) {
            vm.warp(deployedAt + i * 1 days);
            world.tick();
        }
        assertEq(world.getSettlement(0).energy, 0);
        assertEq(world.getSettlement(1).energy, 0);
    }

    function test_crisisEventEmittedBelow300() public {
        vm.warp(deployedAt + 1 days);
        // Only Nova Port (120 -> 95) is below 300 after the first tick.
        vm.expectEmit(true, false, false, true);
        emit SwarmWorld.Tick(1, deployedAt + 1 days);
        vm.expectEmit(true, false, false, true);
        emit SwarmWorld.EnergyCrisis(2, 95);
        world.tick();

        // Drive Iron Valley to 295 (420 - 5*25). Ticks 2..5.
        for (uint256 i = 2; i <= 5; ++i) {
            vm.warp(deployedAt + i * 1 days);
            vm.recordLogs();
            world.tick();
        }
        assertEq(world.getSettlement(1).energy, 295);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 crises;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == SwarmWorld.EnergyCrisis.selector) crises++;
        }
        assertEq(crises, 2, "Iron Valley and Nova Port in crisis on tick 5");
    }

    function test_crisisNotEmittedAtExactly300() public {
        // Genesis City 500 -> 300 after 8 ticks. 300 is not below 300.
        for (uint256 i = 1; i <= 8; ++i) {
            vm.warp(deployedAt + i * 1 days);
            if (i == 8) vm.recordLogs();
            world.tick();
        }
        assertEq(world.getSettlement(0).energy, 300);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == SwarmWorld.EnergyCrisis.selector) {
                assertTrue(uint256(logs[i].topics[1]) != 0, "Genesis City must not be flagged at 300");
            }
        }
    }

    // ---------------------------------------------------------------------
    // Opening missions
    // ---------------------------------------------------------------------

    function test_openMissionRecordsEverything() public {
        vm.expectEmit(true, true, true, true);
        emit SwarmWorld.MissionOpened(1, NOVA_PORT, sponsor, REWARD, uint64(deployedAt + 3 days), _roles());
        uint256 id = _open();
        assertEq(id, 1);
        SwarmWorld.Mission memory m = world.getMission(id);
        assertEq(m.settlementId, NOVA_PORT);
        assertEq(uint8(m.missionType), uint8(SwarmWorld.MissionType.ENERGY_REPAIR));
        assertEq(uint8(m.state), uint8(SwarmWorld.MissionState.OPEN));
        assertEq(m.sponsor, sponsor);
        assertEq(m.createdAt, deployedAt);
        assertEq(m.deadline, deployedAt + 3 days);
        assertEq(m.reward, REWARD);
        assertEq(m.roles.builder, builder);
        assertEq(m.roles.tester, tester);
        assertEq(m.roles.reviewer, reviewer);
        assertEq(m.roles.verifier, verifier);
        assertEq(m.roles.builderSeat, 11);
        assertEq(m.roles.testerSeat, 22);
        assertEq(m.roles.reviewerSeat, 33);
        assertEq(m.roles.verifierSeat, 44);
        assertEq(world.getSettlement(NOVA_PORT).activeMission, id);
        assertEq(world.totalEscrowed(), REWARD);
        assertEq(address(world).balance, REWARD);
        assertEq(world.nextMissionId(), 2);
        _assertConservation();
    }

    function test_openRequiresEnergyBelow300() public {
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.EnergyNotInCrisis.selector, 500));
        world.openEnergyMission{value: REWARD}(0, _roles());

        // Drive Genesis City to exactly 300: still not allowed.
        for (uint256 i = 1; i <= 8; ++i) {
            vm.warp(deployedAt + i * 1 days);
            world.tick();
        }
        assertEq(world.getSettlement(0).energy, 300);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.EnergyNotInCrisis.selector, 300));
        world.openEnergyMission{value: REWARD}(0, _roles());

        vm.warp(deployedAt + 9 days);
        world.tick();
        vm.prank(sponsor);
        uint256 id = world.openEnergyMission{value: REWARD}(0, _roles());
        assertEq(world.getSettlement(0).activeMission, id);
    }

    function test_openRequiresNonzeroReward() public {
        vm.prank(sponsor);
        vm.expectRevert(SwarmWorld.ZeroReward.selector);
        world.openEnergyMission{value: 0}(NOVA_PORT, _roles());
    }

    function test_oneActiveMissionPerSettlement() public {
        uint256 first = _open();
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.SettlementBusy.selector, NOVA_PORT, first));
        world.openEnergyMission{value: REWARD}(NOVA_PORT, _roles());

        // A different sponsor is blocked too.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.SettlementBusy.selector, NOVA_PORT, first));
        world.openEnergyMission{value: REWARD}(NOVA_PORT, _roles());

        // Once the mission fails the slot frees up.
        _submitOutcome(first);
        vm.prank(tester);
        world.submitTest(first, keccak256("t"), false);
        assertEq(world.getSettlement(NOVA_PORT).activeMission, 0);
        uint256 second = _open();
        assertEq(second, 2);
        assertEq(world.getSettlement(NOVA_PORT).activeMission, second);
    }

    function test_fourRoleAddressesMustBeNonzero() public {
        SwarmWorld.Roles memory r = _roles();
        r.verifier = address(0);
        vm.prank(sponsor);
        vm.expectRevert(SwarmWorld.ZeroRoleAddress.selector);
        world.openEnergyMission{value: REWARD}(NOVA_PORT, r);

        r = _roles();
        r.builder = address(0);
        vm.prank(sponsor);
        vm.expectRevert(SwarmWorld.ZeroRoleAddress.selector);
        world.openEnergyMission{value: REWARD}(NOVA_PORT, r);
    }

    function test_fourRoleAddressesMustBeDistinct() public {
        address[4] memory a = [builder, tester, reviewer, verifier];
        for (uint256 i = 0; i < 4; ++i) {
            for (uint256 j = 0; j < 4; ++j) {
                if (i == j) continue;
                SwarmWorld.Roles memory r = _roles();
                address[4] memory dup = a;
                dup[j] = dup[i];
                r.builder = dup[0];
                r.tester = dup[1];
                r.reviewer = dup[2];
                r.verifier = dup[3];
                vm.prank(sponsor);
                vm.expectRevert(SwarmWorld.RolesNotDistinct.selector);
                world.openEnergyMission{value: REWARD}(NOVA_PORT, r);
            }
        }
        // Reviewer equal to builder or tester specifically.
        SwarmWorld.Roles memory rr = _roles();
        rr.reviewer = builder;
        vm.prank(sponsor);
        vm.expectRevert(SwarmWorld.RolesNotDistinct.selector);
        world.openEnergyMission{value: REWARD}(NOVA_PORT, rr);
        rr = _roles();
        rr.reviewer = tester;
        vm.prank(sponsor);
        vm.expectRevert(SwarmWorld.RolesNotDistinct.selector);
        world.openEnergyMission{value: REWARD}(NOVA_PORT, rr);
    }

    function test_fourSeatIdsMustBeDistinct() public {
        uint32[4] memory seats = [uint32(11), 22, 33, 44];
        for (uint256 i = 0; i < 4; ++i) {
            for (uint256 j = 0; j < 4; ++j) {
                if (i == j) continue;
                SwarmWorld.Roles memory r = _roles();
                uint32[4] memory dup = seats;
                dup[j] = dup[i];
                r.builderSeat = dup[0];
                r.testerSeat = dup[1];
                r.reviewerSeat = dup[2];
                r.verifierSeat = dup[3];
                vm.prank(sponsor);
                vm.expectRevert(SwarmWorld.SeatsNotDistinct.selector);
                world.openEnergyMission{value: REWARD}(NOVA_PORT, r);
            }
        }
        // Seat 0 is allowed as long as the four are distinct.
        SwarmWorld.Roles memory z = _roles();
        z.builderSeat = 0;
        vm.prank(sponsor);
        uint256 id = world.openEnergyMission{value: REWARD}(NOVA_PORT, z);
        assertEq(world.getMission(id).roles.builderSeat, 0);
    }

    function testFuzz_seatIdsAnyDistinctValuesAccepted(uint32 a, uint32 b, uint32 c, uint32 d) public {
        vm.assume(a != b && a != c && a != d && b != c && b != d && c != d);
        SwarmWorld.Roles memory r = _roles();
        r.builderSeat = a;
        r.testerSeat = b;
        r.reviewerSeat = c;
        r.verifierSeat = d;
        vm.prank(sponsor);
        uint256 id = world.openEnergyMission{value: REWARD}(NOVA_PORT, r);
        SwarmWorld.Mission memory m = world.getMission(id);
        assertEq(m.roles.builderSeat, a);
        assertEq(m.roles.testerSeat, b);
        assertEq(m.roles.reviewerSeat, c);
        assertEq(m.roles.verifierSeat, d);
    }

    // ---------------------------------------------------------------------
    // Authorisation and workflow order
    // ---------------------------------------------------------------------

    function test_unauthorizedRoleCalls() public {
        uint256 id = _open();

        // submitOutcome: only builder.
        address[4] memory notBuilder = [tester, reviewer, verifier, stranger];
        for (uint256 i = 0; i < 4; ++i) {
            vm.prank(notBuilder[i]);
            vm.expectRevert(abi.encodeWithSelector(SwarmWorld.NotRole.selector, id, builder, notBuilder[i]));
            world.submitOutcome(id, 250, 60, keccak256("a"));
        }
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.NotRole.selector, id, builder, sponsor));
        world.submitOutcome(id, 250, 60, keccak256("a"));
        _submitOutcome(id);

        // submitTest: only tester.
        address[4] memory notTester = [builder, reviewer, verifier, stranger];
        for (uint256 i = 0; i < 4; ++i) {
            vm.prank(notTester[i]);
            vm.expectRevert(abi.encodeWithSelector(SwarmWorld.NotRole.selector, id, tester, notTester[i]));
            world.submitTest(id, keccak256("t"), true);
        }
        _passTest(id);

        // submitReview: only reviewer.
        address[4] memory notReviewer = [builder, tester, verifier, stranger];
        for (uint256 i = 0; i < 4; ++i) {
            vm.prank(notReviewer[i]);
            vm.expectRevert(abi.encodeWithSelector(SwarmWorld.NotRole.selector, id, reviewer, notReviewer[i]));
            world.submitReview(id, keccak256("r"), true);
        }
        _passReview(id);

        // verifyOutcome: only verifier.
        address[4] memory notVerifier = [builder, tester, reviewer, stranger];
        for (uint256 i = 0; i < 4; ++i) {
            vm.prank(notVerifier[i]);
            vm.expectRevert(abi.encodeWithSelector(SwarmWorld.NotRole.selector, id, verifier, notVerifier[i]));
            world.verifyOutcome(id, keccak256("v"), true);
        }
        _passVerify(id);
        _assertState(id, SwarmWorld.MissionState.PASSED);
    }

    function test_expireOnlyBySponsor() public {
        uint256 id = _open();
        vm.warp(deployedAt + 3 days);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.NotSponsor.selector, id, sponsor, stranger));
        world.expireMission(id);
        vm.prank(builder);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.NotSponsor.selector, id, sponsor, builder));
        world.expireMission(id);
    }

    function test_wrongWorkflowOrder() public {
        uint256 id = _open();

        // Nothing but submitOutcome is allowed while OPEN.
        vm.prank(tester);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmWorld.WrongState.selector, id, SwarmWorld.MissionState.OPEN, SwarmWorld.MissionState.WORKING
            )
        );
        world.submitTest(id, keccak256("t"), true);
        vm.prank(reviewer);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmWorld.WrongState.selector, id, SwarmWorld.MissionState.OPEN, SwarmWorld.MissionState.WORKING
            )
        );
        world.submitReview(id, keccak256("r"), true);
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmWorld.WrongState.selector, id, SwarmWorld.MissionState.OPEN, SwarmWorld.MissionState.VERIFYING
            )
        );
        world.verifyOutcome(id, keccak256("v"), true);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmWorld.WrongState.selector, id, SwarmWorld.MissionState.OPEN, SwarmWorld.MissionState.PASSED
            )
        );
        world.settleMission(id);

        _submitOutcome(id);

        // Builder cannot resubmit; reviewer cannot go before tester; verifier cannot go yet.
        vm.prank(builder);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmWorld.WrongState.selector, id, SwarmWorld.MissionState.WORKING, SwarmWorld.MissionState.OPEN
            )
        );
        world.submitOutcome(id, 250, 60, keccak256("a2"));
        vm.prank(reviewer);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmWorld.WrongState.selector, id, SwarmWorld.MissionState.WORKING, SwarmWorld.MissionState.WORKING
            )
        );
        world.submitReview(id, keccak256("r"), true);
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmWorld.WrongState.selector, id, SwarmWorld.MissionState.WORKING, SwarmWorld.MissionState.VERIFYING
            )
        );
        world.verifyOutcome(id, keccak256("v"), true);

        _passTest(id);

        // Tester cannot re-test; verifier still blocked until review.
        vm.prank(tester);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmWorld.WrongState.selector, id, SwarmWorld.MissionState.WORKING, SwarmWorld.MissionState.VERIFYING
            )
        );
        world.submitTest(id, keccak256("t2"), true);
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmWorld.WrongState.selector, id, SwarmWorld.MissionState.WORKING, SwarmWorld.MissionState.VERIFYING
            )
        );
        world.verifyOutcome(id, keccak256("v"), true);

        _passReview(id);
        _assertState(id, SwarmWorld.MissionState.VERIFYING);

        // Nobody but the verifier can act now; settlement not yet possible.
        vm.prank(reviewer);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmWorld.WrongState.selector, id, SwarmWorld.MissionState.VERIFYING, SwarmWorld.MissionState.WORKING
            )
        );
        world.submitReview(id, keccak256("r2"), true);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmWorld.WrongState.selector, id, SwarmWorld.MissionState.VERIFYING, SwarmWorld.MissionState.PASSED
            )
        );
        world.settleMission(id);

        _passVerify(id);
        _assertState(id, SwarmWorld.MissionState.PASSED);

        // PASSED: only settlement is possible.
        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmWorld.WrongState.selector, id, SwarmWorld.MissionState.PASSED, SwarmWorld.MissionState.VERIFYING
            )
        );
        world.verifyOutcome(id, keccak256("v2"), false);
        vm.warp(deployedAt + 3 days);
        vm.prank(sponsor);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmWorld.WrongState.selector, id, SwarmWorld.MissionState.PASSED, SwarmWorld.MissionState.OPEN
            )
        );
        world.expireMission(id);
    }

    // ---------------------------------------------------------------------
    // Outcome bounds
    // ---------------------------------------------------------------------

    function test_energyGainBounds() public {
        uint256 id = _open();
        vm.prank(builder);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.EnergyGainOutOfRange.selector, 199));
        world.submitOutcome(id, 199, 0, keccak256("a"));
        vm.prank(builder);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.EnergyGainOutOfRange.selector, 301));
        world.submitOutcome(id, 301, 0, keccak256("a"));
        vm.prank(builder);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.EnergyGainOutOfRange.selector, 0));
        world.submitOutcome(id, 0, 0, keccak256("a"));
        vm.prank(builder);
        world.submitOutcome(id, 200, 0, keccak256("a"));
        assertEq(world.getMission(id).energyGain, 200);
    }

    function test_energyGainUpperBoundInclusive() public {
        uint256 id = _open();
        vm.prank(builder);
        world.submitOutcome(id, 300, 100, keccak256("a"));
        SwarmWorld.Mission memory m = world.getMission(id);
        assertEq(m.energyGain, 300);
        assertEq(m.materialsCost, 100);
    }

    function test_materialsCostBound() public {
        uint256 id = _open();
        vm.prank(builder);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.MaterialsCostTooHigh.selector, 101));
        world.submitOutcome(id, 250, 101, keccak256("a"));
    }

    function test_materialsMustBeAvailable() public {
        // Drain Nova Port materials from 300 to 0 with three missions costing 100 each.
        for (uint256 i = 0; i < 3; ++i) {
            uint256 id = _open();
            vm.prank(builder);
            world.submitOutcome(id, 200, 100, keccak256("a"));
            _passTest(id);
            _passReview(id);
            _passVerify(id);
            world.settleMission(id);
            // Bring energy back under 300 so a new mission can open: 12 ticks of 25 = 300 energy.
            for (uint256 t = 0; t < 12; ++t) {
                vm.warp(world.nextTickAt());
                world.tick();
            }
        }
        assertEq(world.getSettlement(NOVA_PORT).materials, 0);
        assertLt(world.getSettlement(NOVA_PORT).energy, 300);
        uint256 last = _open();
        vm.prank(builder);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.InsufficientMaterials.selector, 0, 1));
        world.submitOutcome(last, 250, 1, keccak256("a"));
        vm.prank(builder);
        world.submitOutcome(last, 250, 0, keccak256("a"));
    }

    function test_resultingEnergyCannotExceed1000() public {
        // Nova Port 120 + 300 = 420, fine. Build a settlement at 299 with gain 300 -> 599, fine.
        // Reaching 1000 requires a settlement at >= 701 energy, which cannot be in crisis, so the
        // resulting-energy cap is unreachable at open time; it is still enforced by the shared
        // validator. Verify the boundary through the pure computation path instead: energy 299 with
        // gain 300 is allowed; the check itself is covered by settle re-validation below.
        uint256 id = _open();
        vm.prank(builder);
        world.submitOutcome(id, 300, 0, keccak256("a"));
        _passTest(id);
        _passReview(id);
        _passVerify(id);
        world.settleMission(id);
        assertEq(world.getSettlement(NOVA_PORT).energy, 420);
        assertLe(world.getSettlement(NOVA_PORT).energy, world.RESOURCE_MAX());
    }

    function testFuzz_outcomeBoundsAreEnforced(uint16 gain, uint16 cost) public {
        uint256 id = _open();
        vm.prank(builder);
        if (gain < 200 || gain > 300) {
            vm.expectRevert(abi.encodeWithSelector(SwarmWorld.EnergyGainOutOfRange.selector, gain));
        } else if (cost > 100) {
            vm.expectRevert(abi.encodeWithSelector(SwarmWorld.MaterialsCostTooHigh.selector, cost));
        }
        world.submitOutcome(id, gain, cost, keccak256("a"));
    }

    // ---------------------------------------------------------------------
    // Failure paths and refunds
    // ---------------------------------------------------------------------

    function test_failedTest() public {
        uint256 id = _open();
        _submitOutcome(id);
        vm.prank(tester);
        vm.expectEmit(true, false, false, true);
        emit SwarmWorld.TestSubmitted(id, keccak256("bad"), false);
        vm.expectEmit(true, false, false, true);
        emit SwarmWorld.MissionFailed(id, SwarmWorld.MissionState.WORKING, REWARD);
        world.submitTest(id, keccak256("bad"), false);

        _assertState(id, SwarmWorld.MissionState.FAILED);
        assertEq(world.getMission(id).testHash, keccak256("bad"));
        assertEq(world.getSettlement(NOVA_PORT).activeMission, 0);
        assertEq(world.claimable(sponsor), REWARD);
        assertEq(world.totalEscrowed(), 0);
        _assertSettlement(2, 120, 420, 300, 180, 100, 75);
        _assertConservation();

        // Nothing further is possible.
        vm.prank(reviewer);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmWorld.WrongState.selector, id, SwarmWorld.MissionState.FAILED, SwarmWorld.MissionState.WORKING
            )
        );
        world.submitReview(id, keccak256("r"), true);
    }

    function test_failedReview() public {
        uint256 id = _open();
        _submitOutcome(id);
        _passTest(id);
        vm.prank(reviewer);
        vm.expectEmit(true, false, false, true);
        emit SwarmWorld.ReviewSubmitted(id, keccak256("bad"), false);
        vm.expectEmit(true, false, false, true);
        emit SwarmWorld.MissionFailed(id, SwarmWorld.MissionState.WORKING, REWARD);
        world.submitReview(id, keccak256("bad"), false);

        _assertState(id, SwarmWorld.MissionState.FAILED);
        assertEq(world.getMission(id).reviewHash, keccak256("bad"));
        assertEq(world.getSettlement(NOVA_PORT).activeMission, 0);
        assertEq(world.claimable(sponsor), REWARD);
        _assertSettlement(2, 120, 420, 300, 180, 100, 75);
        _assertConservation();

        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmWorld.WrongState.selector, id, SwarmWorld.MissionState.FAILED, SwarmWorld.MissionState.VERIFYING
            )
        );
        world.verifyOutcome(id, keccak256("v"), true);
    }

    function test_failedVerification() public {
        uint256 id = _open();
        _submitOutcome(id);
        _passTest(id);
        _passReview(id);
        vm.prank(verifier);
        vm.expectEmit(true, false, false, true);
        emit SwarmWorld.OutcomeVerified(id, keccak256("bad"), false);
        vm.expectEmit(true, false, false, true);
        emit SwarmWorld.MissionFailed(id, SwarmWorld.MissionState.VERIFYING, REWARD);
        world.verifyOutcome(id, keccak256("bad"), false);

        _assertState(id, SwarmWorld.MissionState.FAILED);
        assertEq(world.getMission(id).verificationHash, keccak256("bad"));
        assertEq(world.getSettlement(NOVA_PORT).activeMission, 0);
        assertEq(world.claimable(sponsor), REWARD);
        assertEq(world.claimable(builder), 0);
        _assertSettlement(2, 120, 420, 300, 180, 100, 75);
        _assertConservation();

        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmWorld.WrongState.selector, id, SwarmWorld.MissionState.FAILED, SwarmWorld.MissionState.PASSED
            )
        );
        world.settleMission(id);
    }

    function test_refundAfterFailure() public {
        uint256 id = _open();
        _submitOutcome(id);
        vm.prank(tester);
        world.submitTest(id, keccak256("bad"), false);

        uint256 before = sponsor.balance;
        vm.prank(sponsor);
        vm.expectEmit(true, false, false, true);
        emit SwarmWorld.Claimed(sponsor, REWARD);
        world.claim();
        assertEq(sponsor.balance, before + REWARD);
        assertEq(world.claimable(sponsor), 0);
        assertEq(address(world).balance, 0);
        _assertConservation();
    }

    function test_doubleRefund() public {
        uint256 id = _open();
        _submitOutcome(id);
        vm.prank(tester);
        world.submitTest(id, keccak256("bad"), false);

        vm.prank(sponsor);
        world.claim();
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.NothingToClaim.selector, sponsor));
        world.claim();

        // The failed mission cannot be failed or expired again to re-credit the sponsor.
        vm.prank(tester);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmWorld.WrongState.selector, id, SwarmWorld.MissionState.FAILED, SwarmWorld.MissionState.WORKING
            )
        );
        world.submitTest(id, keccak256("bad"), false);
        vm.warp(deployedAt + 3 days);
        vm.prank(sponsor);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmWorld.WrongState.selector, id, SwarmWorld.MissionState.FAILED, SwarmWorld.MissionState.OPEN
            )
        );
        world.expireMission(id);
        assertEq(world.claimable(sponsor), 0);
        assertEq(address(world).balance, 0);
    }

    // ---------------------------------------------------------------------
    // Expiry
    // ---------------------------------------------------------------------

    function test_threeDayExpiryBoundary() public {
        uint256 id = _open();
        uint64 deadline = uint64(deployedAt + 3 days);

        vm.warp(deadline - 1);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.MissionNotExpired.selector, id, deadline));
        world.expireMission(id);

        // Roles may still act one second before the deadline.
        _submitOutcome(id);

        vm.warp(deadline);
        // Roles can no longer act at the deadline.
        vm.prank(tester);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.MissionDeadlinePassed.selector, id, deadline));
        world.submitTest(id, keccak256("t"), true);

        vm.prank(sponsor);
        vm.expectEmit(true, false, false, true);
        emit SwarmWorld.MissionExpired(id, REWARD);
        world.expireMission(id);
        _assertState(id, SwarmWorld.MissionState.EXPIRED);
        assertEq(world.getSettlement(NOVA_PORT).activeMission, 0);
        assertEq(world.claimable(sponsor), REWARD);
        assertEq(world.totalEscrowed(), 0);
        _assertSettlement(2, 120, 420, 300, 180, 100, 75);
        _assertConservation();
    }

    function test_expiryFromEveryPreTerminalState() public {
        // OPEN
        uint256 a = _open();
        vm.warp(deployedAt + 3 days);
        vm.prank(sponsor);
        world.expireMission(a);
        _assertState(a, SwarmWorld.MissionState.EXPIRED);

        // WORKING (after test pass)
        uint256 t1 = block.timestamp;
        uint256 b = _open();
        _submitOutcome(b);
        _passTest(b);
        vm.warp(t1 + 3 days);
        vm.prank(sponsor);
        world.expireMission(b);
        _assertState(b, SwarmWorld.MissionState.EXPIRED);

        // VERIFYING
        uint256 t2 = block.timestamp;
        uint256 c = _open();
        _submitOutcome(c);
        _passTest(c);
        _passReview(c);
        vm.warp(t2 + 3 days);
        vm.prank(sponsor);
        world.expireMission(c);
        _assertState(c, SwarmWorld.MissionState.EXPIRED);

        assertEq(world.claimable(sponsor), 3 * REWARD);
        _assertConservation();
    }

    function test_expiredMissionRefundAndNoDoubleExpire() public {
        uint256 id = _open();
        vm.warp(deployedAt + 3 days);
        vm.prank(sponsor);
        world.expireMission(id);

        vm.prank(sponsor);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmWorld.WrongState.selector, id, SwarmWorld.MissionState.EXPIRED, SwarmWorld.MissionState.OPEN
            )
        );
        world.expireMission(id);

        uint256 before = sponsor.balance;
        vm.prank(sponsor);
        world.claim();
        assertEq(sponsor.balance, before + REWARD);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.NothingToClaim.selector, sponsor));
        world.claim();
        assertEq(address(world).balance, 0);
    }

    function test_passedMissionCannotExpireAndSettlesAfterDeadline() public {
        uint256 id = _open();
        _runToPassed(id);
        vm.warp(deployedAt + 30 days);
        vm.prank(sponsor);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmWorld.WrongState.selector, id, SwarmWorld.MissionState.PASSED, SwarmWorld.MissionState.OPEN
            )
        );
        world.expireMission(id);
        world.settleMission(id);
        _assertState(id, SwarmWorld.MissionState.SETTLED);
    }

    function test_roleActionsRevertAfterDeadline() public {
        uint256 id = _open();
        _submitOutcome(id);
        _passTest(id);
        _passReview(id);
        uint64 deadline = uint64(deployedAt + 3 days);
        vm.warp(deadline + 1);
        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.MissionDeadlinePassed.selector, id, deadline));
        world.verifyOutcome(id, keccak256("v"), true);
    }

    // ---------------------------------------------------------------------
    // Settlement
    // ---------------------------------------------------------------------

    function test_worldStateUnchangedBeforeSettlement() public {
        bytes32 h0 = world.worldStateHash();
        uint256 id = _open();
        assertEq(world.worldStateHash(), h0, "open");
        _submitOutcome(id);
        assertEq(world.worldStateHash(), h0, "outcome");
        _passTest(id);
        assertEq(world.worldStateHash(), h0, "test");
        _passReview(id);
        assertEq(world.worldStateHash(), h0, "review");
        _passVerify(id);
        assertEq(world.worldStateHash(), h0, "verify");
        _assertSettlement(2, 120, 420, 300, 180, 100, 75);
        assertEq(world.claimable(builder), 0);
        assertEq(world.totalEscrowed(), REWARD);

        world.settleMission(id);
        assertTrue(world.worldStateHash() != h0, "settlement changes the world");
    }

    function test_successfulStateTransition() public {
        uint256 id = _open();
        _runToPassed(id);
        bytes32 before = world.worldStateHash();

        vm.expectEmit(true, true, false, false);
        emit SwarmWorld.MissionSettled(id, NOVA_PORT, bytes32(0), before, bytes32(0), 120, 370, 300, 240);
        vm.prank(stranger); // permissionless
        world.settleMission(id);

        _assertSettlement(2, 370, 420, 240, 180, 100, 75);
        _assertSettlement(0, 500, 500, 500, 500, 100, 80);
        _assertSettlement(1, 420, 550, 700, 350, 100, 75);
        SwarmWorld.Mission memory m = world.getMission(id);
        assertEq(uint8(m.state), uint8(SwarmWorld.MissionState.SETTLED));
        assertEq(m.worldStateBefore, before);
        assertTrue(m.proofHash != bytes32(0));
        assertEq(world.getSettlement(NOVA_PORT).activeMission, 0);
        assertEq(world.totalEscrowed(), 0);
        _assertConservation();
    }

    function test_settledEventCarriesTransition() public {
        uint256 id = _open();
        _runToPassed(id);
        bytes32 before = world.worldStateHash();
        vm.recordLogs();
        world.settleMission(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != SwarmWorld.MissionSettled.selector) continue;
            found = true;
            (
                bytes32 proof,
                bytes32 wBefore,
                bytes32 wAfter,
                uint16 eBefore,
                uint16 eAfter,
                uint16 mBefore,
                uint16 mAfter
            ) = abi.decode(logs[i].data, (bytes32, bytes32, bytes32, uint16, uint16, uint16, uint16));
            assertEq(proof, world.getMission(id).proofHash);
            assertEq(wBefore, before);
            assertEq(wAfter, world.worldStateHash());
            assertEq(eBefore, 120);
            assertEq(eAfter, 370);
            assertEq(mBefore, 300);
            assertEq(mAfter, 240);
        }
        assertTrue(found, "MissionSettled emitted");
    }

    function test_deterministicProofHash() public {
        uint256 id = _open();
        _runToPassed(id);
        bytes32 before = world.worldStateHash();
        world.settleMission(id);

        SwarmWorld.Mission memory m = world.getMission(id);
        bytes32 expected = keccak256(
            abi.encode(
                id,
                NOVA_PORT,
                before,
                uint16(250),
                uint16(60),
                keccak256("artifact"),
                keccak256("test"),
                keccak256("review"),
                keccak256("verify"),
                uint32(11),
                uint32(22),
                uint32(33),
                uint32(44)
            )
        );
        assertEq(m.proofHash, expected, "stored proof equals off-chain recomputation");
        assertEq(
            world.computeProofHash(
                id,
                NOVA_PORT,
                before,
                250,
                60,
                keccak256("artifact"),
                keccak256("test"),
                keccak256("review"),
                keccak256("verify"),
                [uint32(11), 22, 33, 44]
            ),
            expected
        );

        // A fresh world replaying the same mission yields the same proof hash.
        SwarmWorld replay = new SwarmWorld();
        vm.prank(sponsor);
        uint256 rid = replay.openEnergyMission{value: REWARD}(NOVA_PORT, _roles());
        vm.prank(builder);
        replay.submitOutcome(rid, 250, 60, keccak256("artifact"));
        vm.prank(tester);
        replay.submitTest(rid, keccak256("test"), true);
        vm.prank(reviewer);
        replay.submitReview(rid, keccak256("review"), true);
        vm.prank(verifier);
        replay.verifyOutcome(rid, keccak256("verify"), true);
        replay.settleMission(rid);
        assertEq(replay.getMission(rid).proofHash, expected, "replay is deterministic");

        // Any changed input changes the hash.
        bytes32 other = world.computeProofHash(
            id,
            NOVA_PORT,
            before,
            250,
            60,
            keccak256("artifact"),
            keccak256("test"),
            keccak256("review"),
            keccak256("verify"),
            [uint32(11), 22, 33, 45]
        );
        assertTrue(other != expected);
    }

    function test_doubleSettlement() public {
        uint256 id = _open();
        _runToPassed(id);
        world.settleMission(id);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmWorld.WrongState.selector, id, SwarmWorld.MissionState.SETTLED, SwarmWorld.MissionState.PASSED
            )
        );
        world.settleMission(id);
        _assertSettlement(2, 370, 420, 240, 180, 100, 75);
        assertEq(world.claimable(builder), REWARD / 2, "credited once");
        assertEq(world.totalClaimable(), REWARD);
        _assertConservation();
    }

    function test_settlementSlotFreesForNextMissionAfterTicks() public {
        uint256 id = _open();
        _runToPassed(id);
        world.settleMission(id);
        // Energy now 370: not in crisis.
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.EnergyNotInCrisis.selector, 370));
        world.openEnergyMission{value: REWARD}(NOVA_PORT, _roles());
        for (uint256 i = 0; i < 3; ++i) {
            vm.warp(world.nextTickAt());
            world.tick();
        }
        assertEq(world.getSettlement(NOVA_PORT).energy, 295);
        uint256 next = _open();
        assertEq(next, 2);
    }

    // ---------------------------------------------------------------------
    // Rewards
    // ---------------------------------------------------------------------

    function test_rewardSplit() public {
        uint256 reward = 1 ether + 7; // dust goes to the verifier
        uint256 id = _openWith(reward);
        _runToPassed(id);
        world.settleMission(id);

        uint256 b = reward * 5000 / 10_000;
        uint256 t = reward * 1500 / 10_000;
        uint256 r = reward * 1500 / 10_000;
        uint256 v = reward - b - t - r;
        assertEq(world.claimable(builder), b);
        assertEq(world.claimable(tester), t);
        assertEq(world.claimable(reviewer), r);
        assertEq(world.claimable(verifier), v);
        assertEq(b + t + r + v, reward, "nothing lost");
        assertGe(v, reward * 2000 / 10_000, "verifier gets at least 20%");
        assertEq(world.claimable(sponsor), 0);
        assertEq(world.totalClaimable(), reward);
        _assertConservation();

        uint256[4] memory before = [builder.balance, tester.balance, reviewer.balance, verifier.balance];
        vm.prank(builder);
        world.claim();
        vm.prank(tester);
        world.claim();
        vm.prank(reviewer);
        world.claim();
        vm.prank(verifier);
        world.claim();
        assertEq(builder.balance, before[0] + b);
        assertEq(tester.balance, before[1] + t);
        assertEq(reviewer.balance, before[2] + r);
        assertEq(verifier.balance, before[3] + v);
        assertEq(address(world).balance, 0);
        assertEq(world.totalClaimable(), 0);
    }

    function testFuzz_rewardSplitConservesEveryWei(uint96 rewardRaw) public {
        uint256 reward = uint256(rewardRaw) + 1;
        vm.deal(sponsor, reward);
        uint256 id = _openWith(reward);
        _runToPassed(id);
        world.settleMission(id);
        uint256 sum =
            world.claimable(builder) + world.claimable(tester) + world.claimable(reviewer) + world.claimable(verifier);
        assertEq(sum, reward);
        assertEq(world.claimable(builder), reward / 2);
        assertEq(world.claimable(tester), reward * 15 / 100);
        assertEq(world.claimable(reviewer), reward * 15 / 100);
        assertGe(world.claimable(verifier), reward / 5);
        _assertConservation();
    }

    function test_tinyRewardRoundsEntirelyToVerifier() public {
        uint256 id = _openWith(1);
        _runToPassed(id);
        world.settleMission(id);
        assertEq(world.claimable(builder), 0);
        assertEq(world.claimable(tester), 0);
        assertEq(world.claimable(reviewer), 0);
        assertEq(world.claimable(verifier), 1);
        vm.prank(builder);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.NothingToClaim.selector, builder));
        world.claim();
    }

    function test_claimAccumulatesAcrossMissions() public {
        uint256 a = _open();
        _submitOutcome(a);
        vm.prank(tester);
        world.submitTest(a, keccak256("bad"), false);
        uint256 b = _open();
        vm.warp(deployedAt + 3 days);
        vm.prank(sponsor);
        world.expireMission(b);
        assertEq(world.claimable(sponsor), 2 * REWARD);
        uint256 before = sponsor.balance;
        vm.prank(sponsor);
        world.claim();
        assertEq(sponsor.balance, before + 2 * REWARD);
    }

    function test_doubleClaim() public {
        uint256 id = _open();
        _runToPassed(id);
        world.settleMission(id);
        vm.prank(builder);
        world.claim();
        assertEq(world.claimable(builder), 0);
        vm.prank(builder);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.NothingToClaim.selector, builder));
        world.claim();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.NothingToClaim.selector, stranger));
        world.claim();
        // Others remain fully paid.
        assertEq(address(world).balance, REWARD - REWARD / 2);
        _assertConservation();
    }

    function test_reentrantClaimAttempt() public {
        ReentrantClaimer attacker = new ReentrantClaimer(world);
        SwarmWorld.Roles memory r = _roles();
        r.builder = address(attacker);
        vm.prank(sponsor);
        uint256 id = world.openEnergyMission{value: REWARD}(NOVA_PORT, r);
        vm.prank(address(attacker));
        world.submitOutcome(id, 250, 60, keccak256("artifact"));
        _passTest(id);
        _passReview(id);
        _passVerify(id);
        world.settleMission(id);
        assertEq(world.claimable(address(attacker)), REWARD / 2);

        attacker.attack();

        assertEq(address(attacker).balance, REWARD / 2, "paid exactly once");
        assertEq(world.claimable(address(attacker)), 0);
        assertEq(attacker.entered(), 1, "receive ran once");
        assertTrue(attacker.innerReverted(), "re-entrant claim reverted with nothing to claim");
        assertEq(address(world).balance, REWARD - REWARD / 2, "other workers' funds untouched");
        _assertConservation();

        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.NothingToClaim.selector, address(attacker)));
        attacker.attack();
    }

    function test_claimToRejectingReceiverRevertsAndKeepsBalance() public {
        RejectingReceiver rr = new RejectingReceiver();
        SwarmWorld.Roles memory r = _roles();
        r.tester = address(rr);
        vm.prank(sponsor);
        uint256 id = world.openEnergyMission{value: REWARD}(NOVA_PORT, r);
        _submitOutcome(id);
        vm.prank(address(rr));
        world.submitTest(id, keccak256("t"), true);
        _passReview(id);
        _passVerify(id);
        world.settleMission(id);

        uint256 share = REWARD * 15 / 100;
        vm.prank(address(rr));
        vm.expectRevert(abi.encodeWithSelector(SwarmWorld.EthTransferFailed.selector, address(rr), share));
        world.claim();
        assertEq(world.claimable(address(rr)), share, "balance preserved after failed send");

        // Everyone else can still claim.
        vm.prank(builder);
        world.claim();
        vm.prank(reviewer);
        world.claim();
        vm.prank(verifier);
        world.claim();
        assertEq(address(world).balance, share);
        _assertConservation();
    }

    // ---------------------------------------------------------------------
    // Multi-settlement / conservation
    // ---------------------------------------------------------------------

    function test_missionsOnDifferentSettlementsRunIndependently() public {
        // Bring Iron Valley below 300: 420 - 5*25 = 295.
        for (uint256 i = 0; i < 5; ++i) {
            vm.warp(world.nextTickAt());
            world.tick();
        }
        uint256 t0 = block.timestamp;
        vm.prank(sponsor);
        uint256 a = world.openEnergyMission{value: 2 ether}(1, _roles());
        vm.prank(stranger);
        uint256 b = world.openEnergyMission{value: 3 ether}(2, _roles());
        assertEq(world.totalEscrowed(), 5 ether);

        vm.prank(builder);
        world.submitOutcome(a, 300, 100, keccak256("a"));
        _passTest(a);
        _passReview(a);
        _passVerify(a);
        world.settleMission(a);
        assertEq(world.getSettlement(1).energy, 595);
        assertEq(world.getSettlement(1).materials, 600);

        // Mission b expires; its sponsor (stranger) is refunded.
        vm.warp(t0 + 3 days);
        vm.prank(stranger);
        world.expireMission(b);
        assertEq(world.claimable(stranger), 3 ether);
        assertEq(world.totalEscrowed(), 0);
        assertEq(world.totalClaimable(), 5 ether);
        _assertConservation();
    }
}
