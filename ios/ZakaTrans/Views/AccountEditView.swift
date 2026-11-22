import SwiftUI
import PhotosUI
import UIKit

/// 修改资料：系统 Form。
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
        Form {
            Section {
                HStack {
                    Spacer()
                    PhotosPicker(selection: $picked, matching: .images, photoLibrary: .shared()) {
                        ZStack(alignment: .bottomTrailing) {
                            AvatarView(size: 92)
                            Image(systemName: "camera.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(DSColor.accentFill, in: Circle())
                                .overlay(Circle().strokeBorder(DSColor.cell, lineWidth: 2.5))
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.vertical, DSSpace.xs)
                .listRowBackground(Color.clear)
            }

            Section {
                TextField("请输入昵称", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
            } header: {
                Text("昵称")
            }

            if !error.isEmpty {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(DSColor.destructive)
                }
            }
        }
        .navigationTitle("修改资料")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("保存") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
