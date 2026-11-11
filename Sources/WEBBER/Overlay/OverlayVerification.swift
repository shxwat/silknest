import AppKit
import simd

/// Developer-only replays in the real borderless production panel, with no study scene or diagnostic nodes.
/// Holds a live frame for native window capture; it never runs during an ordinary launch.
final class OverlayVerification {
    let scenario: String
    private let motion: SpiderMotion
    private var held = false, caught = false
    private var minimumSupport = 8
    private var plantedDrift: Float = 0
    private var previous: [(V3,Bool)] = []
    init?(motion: SpiderMotion) {
        guard let name = DevFlags.value("--overlay-check=") else { return nil }
        guard ["idle","crawl","turn","cursor","drag","catch"].contains(name) else { return nil }
        self.motion = motion; scenario = name; motion.autoPatrol = false
        switch name {
        case "crawl": motion.crawl(to:motion.position+V3(-160,40,0))
        case "turn": motion.turn(by:.pi/2)
        case "drag": motion.drag(at:motion.world(V3(70,85,0)))
        case "catch": motion.drag(at:motion.world(V3(0,65,0)))
        default: break
        }
    }
    func update(dt: Float) {
        guard !held else { return }
        if scenario == "catch" && !caught && motion.state == .tracking && motion.stateTime>0.35 {
            caught = motion.catchItem(at:motion.world(V3(0,52,0)))
        }
        motion.update(dt:dt,cursor:scenario == "cursor" ? motion.position+V3(110,0,0) : nil)
        minimumSupport = min(minimumSupport,motion.supportedFeet)
        for (i,foot) in motion.feet.enumerated() where previous.count==8 && previous[i].1 && foot.supported {
            plantedDrift = max(plantedDrift,simd_distance(previous[i].0,foot.position))
        }
        previous = motion.feet.map { ($0.position,$0.supported) }
        switch scenario {
        case "idle": held = motion.time>0.3
        case "crawl": held = motion.state == .crawling && motion.stateTime>0.65 && motion.feet.contains(where:\.swinging)
        case "turn": held = motion.heading>0.82
        case "cursor": held = motion.state == .watching && motion.stateTime>0.25
        case "drag": held = motion.state == .tracking && motion.stateTime>0.5
        case "catch": held = motion.state == .catching && motion.catchTime>0.72
        default: break
        }
        if held {
            let info: [String:Any] = ["scenario":scenario,"state":motion.state.rawValue,"heading":motion.heading,"minimumSupport":minimumSupport,"maximumPlantedDrift":plantedDrift,"bodyOffset":[motion.bodyOffset.x,motion.bodyOffset.y],"bodyLift":motion.bodyLift,"roll":motion.bodyRoll,"feet":motion.feet.map { ["x":$0.position.x,"y":$0.position.y,"z":$0.position.z,"phase":$0.phase.rawValue] as [String:Any] }]
            let directory = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/live-overlay")
            try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            if let data = try? JSONSerialization.data(withJSONObject:info,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:directory.appendingPathComponent(scenario+"-motion.json")) }
            print("Live overlay frame ready: \(scenario); minimum support \(minimumSupport); planted drift \(plantedDrift)")
            fflush(stdout)
        }
    }
}
