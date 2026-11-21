import SwiftUI
import PhotosUI
import UIKit

/// 修改资料：头像和昵称在同一个面板里改。
/// 头像和昵称都是点了就直接弹这里，不再在昵称旁边单独放一颗铅笔图标。
struct AccountEditView: View {
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var app = AppState.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var picked: PhotosPickerItem?
    @State private var saving = false
    @State private var error: String = ""
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 26) {
                    PhotosPicker(selection: $picked, matching: .images, photoLibrary: .shared()) {
                        ZStack(alignment: .bottomTrailing) {
                            AvatarView(size: 92)
                            Image(systemName: "camera.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Theme.accent, in: Circle())
                                .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 2.5))
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 18)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("昵称")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.sub)
                        TextField("请输入昵称", text: $name)
                            .font(.system(size: 17))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .padding(.horizontal, 14)
                            .frame(height: 50)
                            .background(Theme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Theme.hairline, lineWidth: 0.8)
                            )
                    }
                    .padding(.horizontal, 20)

                    if !error.isEmpty {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.warn)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                    }
                }
                .padding(.bottom, 20)
            }

            Button {
                save()
            } label: {
                HStack(spacing: 8) {
                    if saving { ProgressView().tint(.white).scaleEffect(0.85) }
                    Text(saving ? "正在保存" : "保存")
                        .font(.system(size: 17, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle(tint: Theme.accent))
            .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .background(Theme.bg)
        .navigationTitle("修改资料")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
                    .foregroundStyle(Theme.sub)
            }
            ToolbarItem(placement: .confirmationAction) {
                NavigationLink {
                    ProfileView()
                } label: {
                    Text("账号")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = cloud.profile?.display_name ?? ""
        }
        .onChange(of: picked) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    app.setAvatar(img)
                }
                picked = nil
            }
        }
    }

    private func save() {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !saving else { return }
        saving = true
        error = ""
        Task {
            let ok = await cloud.updateDisplayName(t)
            saving = false
            if ok { dismiss() } else { error = cloud.lastError ?? "保存失败，请重试" }
        }
    }
}
