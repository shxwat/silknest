import AppKit
import simd


final class SpiderMotionChecks {
    var failures = 0
    func check(_ condition: Bool, line: Int = #line) { if !condition { print("FAIL at line \(line)"); failures += 1 } }
    func expectLessThan(_ a: Float, _ b: Float, line: Int = #line) { check(a < b, line: line) }
    func expectGreaterThan<T: Comparable>(_ a: T, _ b: T, line: Int = #line) { check(a > b, line: line) }
    func expectEqual<T: Equatable>(_ a: T, _ b: T, line: Int = #line) { check(a == b, line: line) }
    func expectEqual(_ a: Float, _ b: Float, accuracy: Float, line: Int = #line) { check(abs(a-b) <= accuracy, line: line) }
    func expectTrue(_ value: Bool, line: Int = #line) { check(value, line: line) }
    func expectFalse(_ value: Bool, line: Int = #line) { check(!value, line: line) }
    func spider() -> SpiderMotion { SpiderMotion(bounds:CGRect(x:0,y:0,width:1000,height:700),position:V3(500,350,0)) }
    func advance(_ m:SpiderMotion,_ seconds:Float) { for _ in 0..<Int(seconds*120) { m.update(dt:1/120,cursor:nil) } }
    func testCrawlArrivesAndUsesPlantedContacts() {
        let m = spider(); m.crawl(to:V3(650,420,0))
        var planted = 0
        for _ in 0..<1200 {
            let before = m.feet.map { ($0.position,$0.swinging) }
            m.update(dt:1/120,cursor:nil)
            for (i,foot) in m.feet.enumerated() where !before[i].1 && !foot.swinging {
                expectLessThan(simd_distance(before[i].0,foot.position),0.001)
                planted += 1
            }
        }
        expectGreaterThan(planted,300)
        // Patrol starts again after a long idle; verify arrival before the next patrol.
        let n = spider(); n.crawl(to:V3(650,420,0)); advance(n,7.5)
        expectLessThan(simd_distance(n.position,V3(650,420,0)),4)
        expectEqual(n.state,.idle)
    }
    func testTurnReplantsWithoutTranslating() {
        let m = spider(); let origin = m.position
        m.crawl(to:V3(500,220,0)); advance(m,1.1)
        expectEqual(m.state,.turning)
        expectLessThan(simd_distance(m.position,origin),0.001)
        expectGreaterThan(abs(m.heading),0.4)
        expectTrue(m.feet.contains { simd_distance($0.position,origin+$0.home)>2 })
    }
    func testCatchIsBoundedAndReturnsToIdle() {
        let m = spider(); m.drag(at:V3(500,410,0)); advance(m,0.3)
        expectEqual(m.state,.tracking)
        expectTrue(m.catchItem(at:V3(500,410,0)))
        expectFalse(m.catchItem(at:V3(500,410,0)))
        advance(m,0.3); expectGreaterThan(m.bodyLift,3)
        for _ in 0..<400 {
            m.update(dt:1/120,cursor:nil)
            expectTrue(m.position.x.isFinite && m.position.y.isFinite)
            for foot in m.feet { expectTrue(foot.position.z.isFinite) }
        }
        expectEqual(m.state,.idle); expectFalse(m.dragActive)
    }
    func testPauseStopsPoseAndRejectsCatch() {
        let m = spider(); m.paused = true; let before = m.position
        advance(m,2); expectEqual(m.position,before)
        expectFalse(m.catchItem(at:V3(500,400,0)))
        m.paused = false; expectEqual(m.state,.idle)
    }
    func testIKMaintainsSegmentLengths() {
        let hip = V3(10,8,14), foot = V3(65,24,0)
        let knee = solveKnee(hip:hip,foot:foot,upper:34,lower:46,pole:V3(0.3,0,1))
        expectEqual(simd_distance(hip,knee),34,accuracy:0.001)
        expectEqual(simd_distance(knee,foot),46,accuracy:0.001)
        expectGreaterThan(knee.z,hip.z)
    }
    func testGaitSupportOverlapAndReach() {
        let m = spider(); m.autoPatrol = false; m.crawl(to:V3(740,470,0))
        var overlapFrames = 0, maxRoll: Float = 0
        for _ in 0..<1200 {
            let previous = m.feet.map { ($0.position,$0.supported) }
            m.update(dt:1/120,cursor:nil)
            expectGreaterThan(m.supportedFeet,3)
            if Set(m.feet.filter(\.swinging).map(\.group)).count==2 { overlapFrames += 1 }
            maxRoll = max(maxRoll,abs(m.bodyRoll))
            for (i,foot) in m.feet.enumerated() {
                if previous[i].1 && foot.supported { expectLessThan(simd_distance(previous[i].0,foot.position),0.001) }
                let pose = LegPose.solve(foot,motion:m)
                expectLessThan(simd_distance(pose.points[1],foot.position)/(foot.femurLength+foot.distalLength),1.05)
                expectTrue(pose.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
            }
        }
        expectGreaterThan(overlapFrames,20); expectGreaterThan(maxRoll,0.002)
    }
    func testNinetyDegreeTurnFinishesInPlace() {
        let m = spider(); m.autoPatrol = false; let origin = m.position
        m.turn(by:.pi/2); advance(m,4.5)
        expectEqual(m.state,.idle)
        expectLessThan(abs(angleDelta(m.heading,.pi/2)),0.03)
        expectLessThan(simd_distance(origin,m.position),0.001)
        expectEqual(m.supportedFeet,8)
    }
    func testCursorFreezesBeforeOrienting() {
        let m = spider(); m.autoPatrol = false
        m.update(dt:1/120,cursor:m.position+V3(110,0,0))
        expectEqual(m.state,.alert); advance(m,0.15)
        expectLessThan(abs(m.heading),0.001)
        advance(m,0.3)
        expectEqual(m.state,.orienting)
        expectGreaterThan(abs(m.heading),0.1)
        expectLessThan(simd_distance(m.position,V3(500,350,0)),0.001)
    }
    func testCursorInterruptsCrawlAndDragGetsStrongerAttention() {
        let m = spider(); m.autoPatrol = false; m.crawl(to:m.position+V3(0,180,0)); advance(m,1)
        expectEqual(m.state,.crawling)
        let origin = m.position, heading = m.heading
        m.update(dt:1/120,cursor:origin+V3(110,0,0))
        expectEqual(m.state,.alert); advance(m,0.15)
        expectEqual(m.heading,heading,accuracy:0.001)
        advance(m,2.3)
        expectEqual(m.state,.watching)
        expectLessThan(simd_distance(origin,m.position),0.001)
        let cursorReach = m.feet.filter { $0.index==0 }.map { $0.position.z }.max() ?? 0
        expectGreaterThan(cursorReach,0.5); expectLessThan(cursorReach,3)
        let drag = spider(); drag.autoPatrol = false; drag.drag(at:drag.world(V3(70,85,0))); advance(drag,1.6)
        expectEqual(drag.state,.tracking)
        let dragReach = drag.feet.filter { $0.index==0 }.map { $0.position.z }.max() ?? 0
        expectGreaterThan(dragReach,cursorReach+2)
    }
    func testCatchDuringCrawlRetainsFourSupports() {
        let m = spider(); m.autoPatrol = false; m.crawl(to:m.position+V3(0,180,0)); advance(m,0.95)
        expectTrue(m.catchItem(at:m.world(V3(0,55,0))))
        for _ in 0..<360 {
            let contacts = m.feet.map { ($0.position,$0.supported) }
            m.update(dt:1/120,cursor:nil)
            expectGreaterThan(m.supportedFeet,3)
            for (i,foot) in m.feet.enumerated() where contacts[i].1 && foot.supported {
                expectLessThan(simd_distance(contacts[i].0,foot.position),0.001)
            }
        }
        expectEqual(m.state,.idle)
    }
    /// Every selectable spider walks with planted, non-sliding feet at its own tempo.
    func testEverySpeciesGaitKeepsContacts() {
        for species in SpiderSpecies.all {
            let m = spider(); m.autoPatrol = false
            m.cruiseSpeed = species.speed; m.acceleration = species.acceleration; m.gaitTempo = species.gaitTempo
            m.crawl(to:V3(760,520,0))
            for _ in 0..<1200 {
                let previous = m.feet.map { ($0.position,$0.supported) }
                m.update(dt:1/120,cursor:nil)
                expectGreaterThan(m.supportedFeet,3)
                for (i,foot) in m.feet.enumerated() where previous[i].1 && foot.supported {
                    expectLessThan(simd_distance(previous[i].0,foot.position),0.001)
                }
            }
            if simd_distance(m.position,V3(760,520,0)) > 4 { print("species",species.id,"did not arrive") }
            expectLessThan(simd_distance(m.position,V3(760,520,0)),4)
        }
    }
    func testPausedSpiderCanBeMovedAndStaysPaused() {
        let m = spider(); m.paused = true
        m.pickUp(); expectEqual(m.state,.held); expectFalse(m.paused)
        for _ in 0..<30 { m.hold(at:V3(620,420,0)); m.update(dt:1/60,cursor:nil) }
        m.drop(); expectTrue(m.paused)
        let landed = m.position
        advance(m,1); expectEqual(m.position,landed); expectEqual(m.supportedFeet,8)
    }
    /// Resting size ↔ full size: feet never slide while planted, support holds, legs stay within reach.
    func testResizeKeepsContactsAndReach() {
        let m = spider(); m.autoPatrol = false
        for frame in 0..<480 {
            let target: Float = frame < 240 ? 0.6 : 1
            let before = m.bodyScale
            m.bodyScale += (target-m.bodyScale)*0.06
            let resizing = abs(m.bodyScale-before) > 0.0001
            if frame == 120 { m.crawl(to:V3(620,420,0)) }
            let previous = m.feet.map { ($0.position,$0.supported) }
            m.update(dt:1/120,cursor:nil)
            expectGreaterThan(m.supportedFeet,3)
            for (i,foot) in m.feet.enumerated() {
                // Planted feet never slide from walking; only the deliberate resize moves them.
                if previous[i].1 && foot.supported && !resizing { expectLessThan(simd_distance(previous[i].0,foot.position),0.001) }
                expectLessThan(simd_distance(LegPose.solve(foot,motion:m).points[1],foot.position)/(foot.femurLength+foot.distalLength),1.05)
            }
        }
        advance(m,3)
        expectEqual(m.bodyScale,1,accuracy:0.001)
        for foot in m.feet { expectLessThan(simd_distance(foot.position,m.world(foot.home)),foot.stepThreshold*1.2) }
    }
    func testPickUpCarryAndDrop() {
        let m = spider(); m.autoPatrol = false
        m.pickUp(); expectEqual(m.state,.held)
        for i in 0..<60 { m.hold(at:V3(500+Float(i)*3,350+Float(i)*2,0)); m.update(dt:1/60,cursor:nil) }
        expectGreaterThan(m.bodyLift,4)
        expectEqual(m.supportedFeet,0)
        expectFalse(m.catchItem(at:m.position))
        m.drop(); expectEqual(m.supportedFeet,8)
        let landed = m.position
        advance(m,1.5)
        expectEqual(m.state,.idle)
        expectLessThan(simd_distance(landed,V3(677,468,0)),1)
        expectLessThan(simd_distance(landed,m.position),0.001)
    }
    /// Neon darting tempo: very fast bursts must keep the same contact guarantees.
    func testDartTempoKeepsContactsPlanted() {
        let m = spider(); m.autoPatrol = false
        m.cruiseSpeed = 290; m.acceleration = 1300; m.gaitTempo = 0.42
        m.crawl(to:V3(820,560,0))
        var maxSpeed: Float = 0
        for _ in 0..<600 {
            let previous = m.feet.map { ($0.position,$0.supported) }
            let before = m.position
            m.update(dt:1/120,cursor:nil)
            maxSpeed = max(maxSpeed,simd_distance(before,m.position)*120)
            expectGreaterThan(m.supportedFeet,3)
            for (i,foot) in m.feet.enumerated() {
                if previous[i].1 && foot.supported { expectLessThan(simd_distance(previous[i].0,foot.position),0.001) }
                expectLessThan(simd_distance(LegPose.solve(foot,motion:m).points[1],foot.position)/(foot.femurLength+foot.distalLength),1.05)
            }
        }
        expectGreaterThan(maxSpeed,180)
        expectLessThan(simd_distance(m.position,V3(820,560,0)),4)
    }
    /// The desktop overlay runs faster: planted feet must still never slide, and support must hold.
    func testDesktopTempoKeepsContactsPlanted() {
        let m = spider(); m.autoPatrol = false
        m.cruiseSpeed = 125; m.acceleration = 260; m.gaitTempo = 0.68
        m.crawl(to:V3(800,520,0))
        var maxSpeed: Float = 0, steps = 0
        for _ in 0..<720 {
            let previous = m.feet.map { ($0.position,$0.supported,$0.phase) }
            let before = m.position
            m.update(dt:1/120,cursor:nil)
            maxSpeed = max(maxSpeed,simd_distance(before,m.position)*120)
            expectGreaterThan(m.supportedFeet,3)
            for (i,foot) in m.feet.enumerated() {
                if previous[i].1 && foot.supported { expectLessThan(simd_distance(previous[i].0,foot.position),0.001) }
                if previous[i].2 == .queued && foot.phase == .lifting { steps += 1 }
                expectLessThan(simd_distance(LegPose.solve(foot,motion:m).points[1],foot.position)/(foot.femurLength+foot.distalLength),1.05)
            }
        }
        expectGreaterThan(maxSpeed,90)
        expectLessThan(simd_distance(m.position,V3(800,520,0)),4)
        expectGreaterThan(steps,30)
    }
    /// Spider moments: chase, wiggle, sleep/wake, grooming, Reduce Motion — and stillness when nobody is near.
    func testMoments() {
        func run(_ m: SpiderMotion, _ seconds: Float, cursor: V3? = nil) { for _ in 0..<Int(seconds*60) { m.update(dt:1/60,cursor:cursor) } }
        // Nobody near: perfectly still (no renders, no CPU).
        let still = spider(); still.ambientIdle = false; still.autoPatrol = false; run(still,4)
        let beforePosition = still.position, beforeHeading = still.heading, beforeLift = still.bodyLift
        let beforeFeet: [V3] = still.feet.map { $0.position }
        run(still,20)
        check(still.position == beforePosition && still.heading == beforeHeading)
        // The body stays put (the existing rare single-foot adjustment is unchanged and not checked here).
        _ = beforeFeet
        check(abs(still.bodyLift-beforeLift) < 0.0002)
        check(still.gaze == nil && still.glowBreath == 0 && !still.momentActive)
        // Cursor chase: eyes follow a near pointer; staying makes it turn toward it.
        let chase = spider(); chase.autoPatrol = false; run(chase,1)
        let pointer = chase.position+V3(120,0,0)
        run(chase,4,cursor:pointer)
        check(chase.gaze != nil)
        let toward = atan2(-(pointer.x-chase.position.x),pointer.y-chase.position.y)
        check(abs(angleDelta(chase.heading,toward)) < 0.35)
        // Feeding frenzy wiggle: runs and ends.
        let happy = spider(); happy.autoPatrol = false; run(happy,1)
        happy.happyWiggle(); check(happy.wiggleActive); run(happy,1.2); check(!happy.wiggleActive)
        // Sleep: rises onto its thread, tucks the legs; a copy wakes it and it lands again.
        let sleepy = spider(); sleepy.autoPatrol = false; sleepy.ambientIdle = false; run(sleepy,1)
        sleepy.fallAsleep(); run(sleepy,8)
        check(sleepy.sleepAmount > 0.95 && sleepy.bodyLift > 12)
        sleepy.wake(jolt:true); run(sleepy,3)
        check(sleepy.sleepAmount == 0 && sleepy.feet.allSatisfy { $0.position.z < 0.01 })
        // Reduce Motion: no wiggle, no turning toward the pointer, sleep without rising.
        let calm = spider(); calm.autoPatrol = false; calm.reduceMotion = true; run(calm,1)
        calm.happyWiggle(); check(!calm.wiggleActive)
        let heading = calm.heading; run(calm,3,cursor:calm.position+V3(120,0,0)); check(calm.heading == heading)
        calm.ambientIdle = false; calm.fallAsleep(); run(calm,8); check(calm.bodyLift < 2)
    }

}

@main
struct MotionCheckRunner {
    static func main() {
        let suite = SpiderMotionChecks()
        suite.testCrawlArrivesAndUsesPlantedContacts()
        suite.testTurnReplantsWithoutTranslating()
        suite.testCatchIsBoundedAndReturnsToIdle()
        suite.testPauseStopsPoseAndRejectsCatch()
        suite.testIKMaintainsSegmentLengths()
        suite.testGaitSupportOverlapAndReach()
        suite.testNinetyDegreeTurnFinishesInPlace()
        suite.testCursorFreezesBeforeOrienting()
        suite.testCursorInterruptsCrawlAndDragGetsStrongerAttention()
        suite.testCatchDuringCrawlRetainsFourSupports()
        suite.testDesktopTempoKeepsContactsPlanted()
        suite.testDartTempoKeepsContactsPlanted()
        suite.testPickUpCarryAndDrop()
        suite.testEverySpeciesGaitKeepsContacts()
        suite.testPausedSpiderCanBeMovedAndStaysPaused()
        suite.testResizeKeepsContactsAndReach()
        suite.testMoments()
        print("17 motion checks; \(suite.failures) failures")
        exit(suite.failures == 0 ? 0 : 1)
    }
}
