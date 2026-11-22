import SwiftUI

/// 启动页：图标 + 名字 + 副标题，居中，不带动画特效。
/// 底跟主界面是同一层环境色，启动页淡出时不会从「一块白」跳成「有底色」。
struct SplashView: View {
    var body: some View {
        ZStack {
            AmbientBackground()

            VStack(spacing: 14) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                Text("语幕")
                    .font(.largeTitle.weight(.semibold))
                    .tracking(3)
                    .foregroundStyle(DSColor.label)

                Text("实时字幕　同声传译")
                    .font(.subheadline)
                    .foregroundStyle(DSColor.secondaryLabel)
            }
            .offset(y: -30)
        }
    }
}
