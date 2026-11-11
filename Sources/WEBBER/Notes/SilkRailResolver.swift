import CoreGraphics
import Foundation

/// Where Silk Notes live on one display: a row of little spiders hanging from the top edge, and the direction
/// a note peeks into. All coordinates are display-local (origin at the visible frame's lower-left).
struct SilkRail: Equatable {
    enum Side: String { case top }
    var side: Side
    /// Where the first knot sits.
    var start: CGPoint
    /// Unit vector along the rail (knots are laid out from `start` in this direction).
    var direction: CGPoint
    /// Usable length along the rail.
    var length: CGFloat
    /// Unit vector a note peeks into (toward free space / away from the edge it hangs on).
    var outward: CGPoint

    static let spacing: CGFloat = 64

    func point(_ index: Int) -> CGPoint {
        CGPoint(x:start.x+direction.x*Self.spacing*CGFloat(index),y:start.y+direction.y*Self.spacing*CGFloat(index))
    }
    var capacity: Int { max(1,Int(length/Self.spacing)) }
}

/// Notes hang below the menu bar and app toolbar, including full-screen browser chrome.
/// Window movement and app switching
/// never change their position; each preview opens downward into the display.
enum SilkRailResolver {
    struct Input {
        var bounds: CGSize
        var window: CGRect?
        var fullscreen = false
    }

    /// Keeps the entire 26-point click target below a 96-point toolbar band.
    static let topInset: CGFloat = 112

    static func resolve(_ input: Input) -> SilkRail {
        let width = input.bounds.width, height = input.bounds.height
        let startX = max(24,width*0.74)
        let endX = min(startX,max(24,width*0.26))
        return SilkRail(side:.top,start:CGPoint(x:startX,y:max(14,height-topInset)),
                        direction:CGPoint(x:-1,y:0),length:startX-endX,
                        outward:CGPoint(x:0,y:-1))
    }
}

/// Free placement keeps the handle on screen and chooses the nearest edge for its silk.
/// Stored fractions survive resolution changes; the browser toolbar remains click-through.
enum NotePlacement {
    static func clamp(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let maxX = max(16,size.width-16), maxY = max(16,size.height-SilkRailResolver.topInset)
        return CGPoint(x:min(max(point.x.isFinite ? point.x : 16,16),maxX),
                       y:min(max(point.y.isFinite ? point.y : 16,16),maxY))
    }

    /// Defaults start spaciously at the top, then continue down the side edges.
    /// Additional notes occupy inset rows; every note remains directly accessible.
    static func defaultPoint(_ index: Int, in size: CGSize) -> CGPoint {
        let rail = SilkRailResolver.resolve(.init(bounds:size))
        if index < rail.capacity { return clamp(rail.point(index),in:size) }
        let sideCount = max(1,Int(max(0,size.height-SilkRailResolver.topInset-32)/SilkRail.spacing))
        let next = index-rail.capacity
        if next < sideCount*2 {
            return clamp(CGPoint(x:next % 2 == 0 ? size.width-16 : 16,
                                 y:rail.start.y-CGFloat(next/2+1)*SilkRail.spacing),in:size)
        }
        let extra = next-sideCount*2
        return clamp(CGPoint(x:rail.point(extra % rail.capacity).x,
                             y:rail.start.y-CGFloat(extra/rail.capacity+1)*SilkRail.spacing),in:size)
    }

    static func normalized(_ point: CGPoint, in size: CGSize) -> NotePosition {
        let point = clamp(point,in:size)
        return NotePosition(x:Double(point.x/max(1,size.width)),y:Double(point.y/max(1,size.height)))
    }

    static func point(_ position: NotePosition, in size: CGSize) -> CGPoint {
        clamp(CGPoint(x:CGFloat(position.x)*size.width,y:CGFloat(position.y)*size.height),in:size)
    }

    static func outward(at point: CGPoint, in size: CGSize) -> CGPoint {
        let distances: [(CGFloat,CGPoint)] = [
            (max(0,size.height-SilkRailResolver.topInset-point.y),CGPoint(x:0,y:-1)),
            (max(0,point.x-16),CGPoint(x:1,y:0)),
            (max(0,size.width-16-point.x),CGPoint(x:-1,y:0)),
            (max(0,point.y-16),CGPoint(x:0,y:1))
        ]
        return distances.min { $0.0 < $1.0 }!.1
    }

    static func anchor(at point: CGPoint, outward: CGPoint, in bounds: CGRect) -> CGPoint {
        if outward.x > 0 { return CGPoint(x:bounds.minX,y:point.y) }
        if outward.x < 0 { return CGPoint(x:bounds.maxX,y:point.y) }
        if outward.y > 0 { return CGPoint(x:point.x,y:bounds.minY) }
        return CGPoint(x:point.x,y:bounds.maxY)
    }
}
