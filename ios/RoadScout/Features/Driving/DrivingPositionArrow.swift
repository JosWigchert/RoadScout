import SwiftUI

private struct NavigationArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.height * 0.04))
            path.addLine(to: CGPoint(x: rect.width * 0.94, y: rect.height * 0.94))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.height * 0.73))
            path.addLine(to: CGPoint(x: rect.width * 0.06, y: rect.height * 0.94))
            path.closeSubpath()
        }
    }
}

struct DrivingPositionArrow: View {
    let rotation: Double

    var body: some View {
        NavigationArrowShape()
            .fill(.white)
            .overlay {
                NavigationArrowShape().stroke(.black.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
            .frame(width: 36, height: 44)
            .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
            .rotationEffect(.degrees(rotation))
            .accessibilityHidden(true)
    }
}

#Preview("Driving · white position arrow") {
    ZStack {
        Color.gray.opacity(0.3)
        DrivingPositionArrow(rotation: 25)
    }
    .frame(width: 200, height: 200)
}
