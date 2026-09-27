import CoreGraphics
import Foundation

/// 3x3 투영 변환(호모그래피). 행 우선(row-major)으로 저장한다.
///
/// 이 프로젝트에서는 주로 "종이 템플릿 좌표(mm)" → "카메라 이미지 정규화 좌표(0...1, 좌상단 원점)" 변환에 쓴다.
struct Homography: Equatable {
    private(set) var m: [Double]

    init(_ m: [Double]) {
        precondition(m.count == 9, "Homography는 9개 원소가 필요합니다")
        self.m = m
    }

    static let identity = Homography([1, 0, 0, 0, 1, 0, 0, 0, 1])

    func apply(_ p: CGPoint) -> CGPoint? {
        let x = Double(p.x), y = Double(p.y)
        let w = m[6] * x + m[7] * y + m[8]
        guard abs(w) > 1e-12 else { return nil }
        return CGPoint(x: (m[0] * x + m[1] * y + m[2]) / w,
                       y: (m[3] * x + m[4] * y + m[5]) / w)
    }

    /// 여러 점을 한꺼번에 변환한다. 하나라도 무한대로 가면 nil.
    func apply(_ points: [CGPoint]) -> [CGPoint]? {
        var result: [CGPoint] = []
        result.reserveCapacity(points.count)
        for p in points {
            guard let q = apply(p) else { return nil }
            result.append(q)
        }
        return result
    }

    /// self를 먼저 적용한 뒤 other를 적용하는 변환.
    func followed(by other: Homography) -> Homography {
        Homography(Self.multiply(other.m, m))
    }

    var inverse: Homography? {
        let a = m
        let c00 = a[4] * a[8] - a[5] * a[7]
        let c01 = a[5] * a[6] - a[3] * a[8]
        let c02 = a[3] * a[7] - a[4] * a[6]
        let det = a[0] * c00 + a[1] * c01 + a[2] * c02
        guard abs(det) > 1e-15 else { return nil }
        let adjugate = [
            c00, a[2] * a[7] - a[1] * a[8], a[1] * a[5] - a[2] * a[4],
            c01, a[0] * a[8] - a[2] * a[6], a[2] * a[3] - a[0] * a[5],
            c02, a[1] * a[6] - a[0] * a[7], a[0] * a[4] - a[1] * a[3],
        ]
        return Homography(adjugate.map { $0 / det }).normalized()
    }

    /// m[8] == 1 이 되도록 스케일을 맞춘다 (가능한 경우).
    func normalized() -> Homography {
        guard abs(m[8]) > 1e-12 else { return self }
        return Homography(m.map { $0 / m[8] })
    }

    // MARK: - 추정

    /// 4쌍 이상의 대응점으로 호모그래피를 추정한다 (정규화 DLT + 최소제곱).
    /// 점이 부족하거나, 세 점 이상이 한 직선 위에 있는 등 배치가 퇴화되면 nil.
    static func estimate(from source: [CGPoint], to destination: [CGPoint]) -> Homography? {
        // 원본 점 배치가 퇴화면(예: 한 줄 위 세 점 + 한 점) 검출 잡음 때문에 수치상으로는 풀려도
        // 엉터리 해가 나오므로 미리 걸러낸다.
        guard source.count == destination.count, source.count >= 4,
              Geometry.hasFourPointsInGeneralPosition(source),
              let ts = normalizingTransform(for: source),
              let td = normalizingTransform(for: destination),
              let tdInverse = td.inverse,
              let s = ts.apply(source),
              let d = td.apply(destination)
        else { return nil }

        // h33 = 1 로 고정한 8개 미지수에 대한 정규방정식 AᵀA h = Aᵀb
        var ata = [Double](repeating: 0, count: 64)
        var atb = [Double](repeating: 0, count: 8)
        func accumulate(_ row: [Double], _ rhs: Double) {
            for i in 0..<8 {
                atb[i] += row[i] * rhs
                for j in 0..<8 {
                    ata[i * 8 + j] += row[i] * row[j]
                }
            }
        }
        for (p, q) in zip(s, d) {
            let x = Double(p.x), y = Double(p.y), u = Double(q.x), v = Double(q.y)
            accumulate([x, y, 1, 0, 0, 0, -u * x, -u * y], u)
            accumulate([0, 0, 0, x, y, 1, -v * x, -v * y], v)
        }
        guard let h = solveLinearSystem(ata, atb, size: 8) else { return nil }

        // H = Td⁻¹ · Hn · Ts
        let hn = h + [1]
        return Homography(multiply(tdInverse.m, multiply(hn, ts.m))).normalized()
    }

    /// 평균 원점 거리가 √2 가 되도록 옮기고 늘리는 변환 (Hartley 정규화).
    private static func normalizingTransform(for points: [CGPoint]) -> Homography? {
        let n = Double(points.count)
        let cx = points.reduce(0.0) { $0 + Double($1.x) } / n
        let cy = points.reduce(0.0) { $0 + Double($1.y) } / n
        let meanDistance = points.reduce(0.0) { $0 + hypot(Double($1.x) - cx, Double($1.y) - cy) } / n
        guard meanDistance > 1e-12 else { return nil }
        let s = 2.0.squareRoot() / meanDistance
        return Homography([s, 0, -s * cx, 0, s, -s * cy, 0, 0, 1])
    }

    static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 {
                r[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j]
            }
        }
        return r
    }

    /// 부분 피벗 가우스 소거. 특이(singular)에 가까우면 nil.
    private static func solveLinearSystem(_ matrix: [Double], _ rhs: [Double], size n: Int) -> [Double]? {
        var a = matrix, b = rhs
        let scale = a.map(abs).max() ?? 0
        guard scale > 0 else { return nil }

        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<n where abs(a[r * n + col]) > abs(a[pivot * n + col]) {
                pivot = r
            }
            guard abs(a[pivot * n + col]) > scale * 1e-10 else { return nil }
            if pivot != col {
                for k in 0..<n { a.swapAt(col * n + k, pivot * n + k) }
                b.swapAt(col, pivot)
            }
            let p = a[col * n + col]
            for r in (col + 1)..<n {
                let f = a[r * n + col] / p
                if f == 0 { continue }
                for k in col..<n { a[r * n + k] -= f * a[col * n + k] }
                b[r] -= f * b[col]
            }
        }

        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[r]
            for k in (r + 1)..<n { sum -= a[r * n + k] * x[k] }
            x[r] = sum / a[r * n + r]
        }
        return x
    }
}

enum Geometry {
    /// 순환 순서(a, b, c, d)로 주어진 사각형의 두 대각선 a–c, b–d 의 교점.
    /// 정사각형 마커의 중심이 원근 변환 뒤 찍히는 정확한 위치다 (꼭짓점 평균은 원근에서 어긋난다).
    static func diagonalIntersection(_ quad: [CGPoint]) -> CGPoint? {
        guard quad.count == 4 else { return nil }
        return lineIntersection(quad[0], quad[2], quad[1], quad[3])
    }

    /// 직선 p1–p2 와 직선 p3–p4 의 교점. 평행하면 nil.
    static func lineIntersection(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> CGPoint? {
        let d1x = p2.x - p1.x, d1y = p2.y - p1.y
        let d2x = p4.x - p3.x, d2y = p4.y - p3.y
        let denominator = d1x * d2y - d1y * d2x
        guard abs(denominator) > 1e-12 else { return nil }
        let t = ((p3.x - p1.x) * d2y - (p3.y - p1.y) * d2x) / denominator
        return CGPoint(x: p1.x + t * d1x, y: p1.y + t * d1y)
    }

    /// 순환 순서로 주어진 사각형이 볼록(뒤틀리거나 꼬이지 않음)한지.
    static func isConvexQuad(_ quad: [CGPoint]) -> Bool {
        guard quad.count == 4 else { return false }
        var expectedSign: CGFloat = 0
        for i in 0..<4 {
            let a = quad[i], b = quad[(i + 1) % 4], c = quad[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) < 1e-12 { return false }
            let sign: CGFloat = cross > 0 ? 1 : -1
            if expectedSign == 0 {
                expectedSign = sign
            } else if sign != expectedSign {
                return false
            }
        }
        return true
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// 어느 세 점도 한 직선 위에 있지 않은 4점 조합이 하나라도 있는지.
    /// 호모그래피가 유일하게 정해지기 위한 조건이다.
    static func hasFourPointsInGeneralPosition(_ points: [CGPoint], tolerance: CGFloat = 1e-3) -> Bool {
        let n = points.count
        guard n >= 4 else { return false }
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return false }
        let spread = max(maxX - minX, maxY - minY)
        guard spread > 0 else { return false }
        let minArea = tolerance * spread * spread

        func area(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
        }
        for i in 0..<n {
            for j in (i + 1)..<n {
                for k in (j + 1)..<n {
                    for l in (k + 1)..<n {
                        let (a, b, c, d) = (points[i], points[j], points[k], points[l])
                        if area(a, b, c) > minArea, area(a, b, d) > minArea,
                           area(a, c, d) > minArea, area(b, c, d) > minArea {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }
}
