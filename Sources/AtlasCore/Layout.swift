import Foundation

public struct MapRect: Sendable {
    public var x: Double; public var y: Double; public var w: Double; public var h: Double
    public var area: Double { w * h }
    public init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) { self.x=x; self.y=y; self.w=w; self.h=h }
    public func inset(_ n: Double) -> MapRect { let d = min(n, min(w,h) * 0.1); return MapRect(x+d,y+d,max(0,w-2*d),max(0,h-2*d)) }
}
public struct MapTile: Sendable {
    public let fileID: Int
    public let rect: MapRect
    public let group: String
    public let height: Double
}
public struct FolderLabel: Sendable { public let name: String; public let path: String; public let rect: MapRect; public let depth: Int }
public struct MapLayout: Sendable {
    public let tiles: [MapTile]
    public let folders: [FolderLabel]
    public init(tiles: [MapTile], folders: [FolderLabel]) { self.tiles=tiles; self.folders=folders }
}
private final class Tree {
    var children: [String: Tree] = [:]
    var file: Int?; var weight: Double = 0
}
public enum AtlasSizing:Int,Sendable { case balanced, lines, bytes, equal }
public enum Treemap {
    public static func squarify(weights: [Double], in bounds: MapRect) -> [MapRect] {
        guard bounds.w > 0, bounds.h > 0, !weights.isEmpty else { return [] }
        let total = weights.reduce(0) { $0 + max(0.001,$1) }
        let areas = weights.map { max(0.001,$0) / total * bounds.area }
        var result = Array(repeating: MapRect(0,0,0,0), count: weights.count)
        var box = bounds; var row: [Int] = []; var cursor = 0
        func worst(_ ids: [Int], _ side: Double) -> Double {
            guard side > 0, let first = ids.first else { return .infinity }
            var lo=areas[first], hi=areas[first], sum=0.0
            for id in ids { lo=min(lo,areas[id]); hi=max(hi,areas[id]); sum += areas[id] }
            return max(side*side*hi/(sum*sum), sum*sum/(side*side*lo))
        }
        func place(_ ids: [Int]) {
            let sum = ids.reduce(0.0) { $0 + areas[$1] }
            if box.w >= box.h {
                let width = sum / max(box.h,0.000001); var y=box.y
                for id in ids { let h=areas[id]/max(width,0.000001); result[id]=MapRect(box.x,y,width,h); y += h }
                box.x += width; box.w=max(0,box.w-width)
            } else {
                let height=sum/max(box.w,0.000001); var x=box.x
                for id in ids { let w=areas[id]/max(height,0.000001); result[id]=MapRect(x,box.y,w,height); x += w }
                box.y += height; box.h=max(0,box.h-height)
            }
        }
        while cursor < areas.count {
            let candidate = row + [cursor]
            if row.isEmpty || worst(candidate,min(box.w,box.h)) <= worst(row,min(box.w,box.h)) { row=candidate; cursor += 1 }
            else { place(row); row=[] }
        }
        if !row.isEmpty { place(row) }
        return result
    }
    public static func layout(_ files: [SourceFile], sizing:AtlasSizing = .lines) -> MapLayout {
        let root=Tree()
        func weight(_ file:SourceFile) -> Double {
            switch sizing {
            case .equal:return 1
            case .bytes:return Double(max(1,file.bytes))
            case .lines:return Double(max(1,file.lines))
            case .balanced:return max(1,log2(Double(max(2,file.bytes))))
            }
        }
        for (id,file) in files.enumerated() {
            var node=root; let weight=weight(file); node.weight += weight
            for part in file.path.split(separator: "/") {
                let key=String(part); if node.children[key] == nil { node.children[key]=Tree() }
                node=node.children[key]!; node.weight += weight
            }
            node.file=id
        }
        var tiles: [MapTile]=[]; var labels: [FolderLabel]=[]
        func visit(_ node: Tree, _ bounds: MapRect, _ depth: Int, _ group: String, _ parent: String) {
            if let file=node.file {
                tiles.append(MapTile(fileID:file,rect:bounds.inset(0.5),group:group,height:8+log2(Double(max(1,files[file].lines)))*5)); return
            }
            let children=node.children.sorted { $0.value.weight == $1.value.weight ? $0.key < $1.key : $0.value.weight > $1.value.weight }
            let rectangles=squarify(weights:children.map { $0.value.weight },in:bounds)
            for (i,child) in children.enumerated() {
                var rect=rectangles[i].inset(depth == 0 ? 3 : 1)
                if child.value.file == nil {
                    labels.append(FolderLabel(name:child.key,path:parent+child.key,rect:rect,depth:depth))
                    let header=min(13,rect.h*0.09); rect.y += header; rect.h -= header
                }
                visit(child.value,rect,depth+1,depth == 0 ? child.key : group,parent+child.key+"/")
            }
        }
        visit(root,MapRect(0,0,1600,1000),0,"","")
        return MapLayout(tiles:tiles,folders:labels)
    }
}
