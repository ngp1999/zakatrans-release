import SwiftUI

/// 启动页：图标 + 名字 + 副标题，居中，不带动画特效。
struct SplashView: View {
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 14) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                Text("语幕")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.ink)

                Text("实时字幕　同声传译")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.sub)
            }
            .offset(y: -30)
        }
    }
}
