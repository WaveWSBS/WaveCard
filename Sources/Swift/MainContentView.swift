import SwiftUI

struct MainContentView: View {
    @StateObject private var vm = AppViewModel()
    @State private var manualHashInput: String = ""
    @State private var manualLabelInput: String = ""

    var body: some View {
        NavigationSplitView {
            AppSidebarView(vm: vm)
        } detail: {
            Group {
                switch vm.selectedNav {
                case .cards:
                    CardsWorkspaceView(vm: vm)
                case .backups:
                    BackupsView(vm: vm)
                case .logs:
                    LogsView(vm: vm)
                }
            }
            .inspector(isPresented: Binding(
                get: { vm.selectedCardId != nil && vm.selectedNav == .cards },
                set: { isShown in
                    if !isShown { vm.selectedCardId = nil }
                }
            )) {
                if let selectedId = vm.selectedCardId {
                    CardInspectorView(vm: vm, cardId: selectedId)
                }
            }
        }
        .sheet(isPresented: $vm.showAddCardSheet) {
            VStack(spacing: 16) {
                Text("Add Card Manually")
                    .font(.system(size: 15, weight: .bold))

                Text("Enter the unique Apple Wallet pass hash (e.g. from syslog or previous export).")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 6) {
                    Text("CARD LABEL (OPTIONAL)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    TextField("e.g. Chase Sapphire, Suica, Amex", text: $manualLabelInput)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("PASS HASH (REQUIRED)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    TextField("27-character base64 hash", text: $manualHashInput)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Button("Cancel") {
                        vm.showAddCardSheet = false
                        manualHashInput = ""
                        manualLabelInput = ""
                    }
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button("Add Card") {
                        vm.addCardManually(id: manualHashInput, label: manualLabelInput)
                        vm.showAddCardSheet = false
                        manualHashInput = ""
                        manualLabelInput = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(manualHashInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 8)
            }
            .padding(20)
            .frame(width: 380)
        }
        .sheet(isPresented: $vm.showBackupModal) {
            BackupCardsSheetView(vm: vm)
        }
        .alert(vm.successAlertTitle, isPresented: $vm.showSuccessAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(vm.successAlertMessage)
        }
        .alert("Notice", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .navigationTitle("WaveCard")
        .frame(minWidth: 920, minHeight: 620)
    }
}
