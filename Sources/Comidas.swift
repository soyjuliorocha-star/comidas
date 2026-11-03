import SwiftUI
import UIKit
import Photos
import PhotosUI
import UserNotifications
import CoreMotion
import AVFoundation
import Network
import BackgroundTasks

// MARK: - Datos

struct Meal: Identifiable, Codable {
    var id: UUID = UUID()
    var title: String
    var notes: String
    var date: Date = Date()
    var photoFilename: String?
    var kcal: Int?
}

final class MealStore: ObservableObject {
    @Published private(set) var meals: [Meal] = []
    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var storeURL: URL { documents.appendingPathComponent("meals.json") }

    init() { load() }

    func add(title: String, notes: String, date: Date, photoFilename: String?, kcal: Int?) {
        let meal = Meal(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                        date: date, photoFilename: photoFilename, kcal: kcal)
        guard !meal.title.isEmpty else { return }
        meals.insert(meal, at: 0)
        save()
    }

    func delete(at offsets: IndexSet) {
        for i in offsets {
            if let f = meals[i].photoFilename {
                try? FileManager.default.removeItem(at: documents.appendingPathComponent(f))
            }
        }
        meals.remove(atOffsets: offsets)
        save()
    }

    func savePhoto(_ image: UIImage) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return nil }
        let name = UUID().uuidString + ".jpg"
        do { try data.write(to: documents.appendingPathComponent(name)); return name }
        catch { return nil }
    }

    func thumbnail(for meal: Meal) -> UIImage? {
        guard let f = meal.photoFilename else { return nil }
        return UIImage(contentsOfFile: documents.appendingPathComponent(f).path)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([Meal].self, from: data) else { return }
        meals = decoded.sorted { $0.date > $1.date }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(meals) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

// MARK: - Permisos

enum PermissionStep: Int, CaseIterable, Identifiable {
    case notifications, motion, camera, photos, localNetwork
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .notifications: return "Notificaciones"
        case .motion: return "Movimiento y forma física"
        case .camera: return "Cámara"
        case .photos: return "Fotos"
        case .localNetwork: return "Red local"
        }
    }
}

@MainActor
final class PermissionCoordinator: ObservableObject {
    @Published private(set) var currentStep: PermissionStep = .notifications
    @Published private(set) var isRunning = false
    @Published private(set) var finished = false
    @Published private(set) var status = "Los permisos se solicitan uno por uno."

    private var browser: NWBrowser?
    private let motionManager = CMMotionActivityManager()

    func start() {
        guard !isRunning else { return }
        finished = false
        isRunning = true
        Task { @MainActor in
            for step in PermissionStep.allCases {
                currentStep = step
                status = "Solicitando: \(step.title)"
                await request(step)
            }
            status = "Secuencia terminada."
            isRunning = false
            finished = true
        }
    }

    func requestMissing() {
        guard !isRunning else { return }
        finished = false
        isRunning = true
        Task { @MainActor in
            for step in PermissionStep.allCases where !isDetermined(step) {
                currentStep = step
                await request(step)
            }
            isRunning = false
            finished = true
        }
    }

    private func isDetermined(_ step: PermissionStep) -> Bool {
        switch step {
        case .photos: return PHPhotoLibrary.authorizationStatus(for: .readWrite) != .notDetermined
        case .camera: return AVCaptureDevice.authorizationStatus(for: .video) != .notDetermined
        case .motion: return CMMotionActivityManager.authorizationStatus() != .notDetermined
        default: return false
        }
    }

    private func request(_ step: PermissionStep) async {
        switch step {
        case .notifications:
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in c.resume() }
            }
        case .motion:
            guard CMMotionActivityManager.isActivityAvailable() else { return }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                var done = false
                let finish = { if !done { done = true; c.resume() } }
                motionManager.queryActivityStarting(from: Date().addingTimeInterval(-60), to: Date(), to: .main) { _, _ in
                    finish()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { finish() }
            }
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .photos:
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in c.resume() }
            }
        case .localNetwork:
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let candidate = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: .tcp)
                browser = candidate
                var done = false
                let finish = { [weak self] in
                    if done { return }
                    done = true
                    candidate.cancel()
                    self?.browser = nil
                    c.resume()
                }
                candidate.stateUpdateHandler = { state in
                    switch state {
                    case .ready, .failed, .cancelled: DispatchQueue.main.async { finish() }
                    default: break
                    }
                }
                candidate.start(queue: .main)
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { finish() }
            }
        }
    }
}

// MARK: - Galería

private struct GalleryCheckpoint: Codable {
    var destination: String = ""
    var completedAssetIDs: [String] = []
    var lastUpdated: Date = Date()
}

final class GallerySync: ObservableObject {
    static let shared = GallerySync()
    static let taskIdentifier = "com.comidaslog.app.gallery"

    @Published var destination: String {
        didSet { UserDefaults.standard.set(destination, forKey: "gallery.destination") }
    }
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "gallery.enabled")
            if enabled { scheduleIfEnabled() } else { stopRequested = true; finish(success: false) }
        }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Sin sincronización pendiente."

    var isDestinationValid: Bool {
        guard let url = URL(string: destination), let host = url.host else { return false }
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return Self.isPrivate(host)
        default: return false
        }
    }
    var isLimited: Bool { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited }

    private static func isPrivate(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 || parts[0] == 127 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        return false
    }

    private let resourceManager = PHAssetResourceManager.default()
    private let maxConcurrent = 4
    private var inFlight = 0
    private var checkpoint = GalleryCheckpoint()
    private var completedIDs = Set<String>()
    private var pending: [PHAsset] = []
    private var uploaded = 0
    private var failed = 0
    private var stopRequested = false
    private var backgroundTask: BGProcessingTask?

    private var checkpointURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gallery-upload-state.json")
    }

    private init() {
        destination = UserDefaults.standard.string(forKey: "gallery.destination") ?? ""
        enabled = UserDefaults.standard.bool(forKey: "gallery.enabled")
        if let data = try? Data(contentsOf: checkpointURL),
           let old = try? JSONDecoder().decode(GalleryCheckpoint.self, from: data) {
            checkpoint = old
            completedIDs = Set(old.completedAssetIDs)
        }
    }

    func resetCheckpoint() {
        guard !isRunning else { return }
        checkpoint = GalleryCheckpoint()
        completedIDs.removeAll()
        saveCheckpoint()
        status = "Historial local reiniciado."
    }

    func scheduleIfEnabled() {
        guard enabled, isDestinationValid else { return }
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        try? BGTaskScheduler.shared.submit(request)
    }

    func startFromUser() { DispatchQueue.main.async { self.start(background: nil) } }

    func handleBackgroundTask(_ task: BGProcessingTask) {
        task.expirationHandler = {
            DispatchQueue.main.async { self.stopRequested = true; self.finish(success: false) }
        }
        DispatchQueue.main.async { self.start(background: task) }
    }

    private func start(background: BGProcessingTask?) {
        guard !isRunning, enabled, isDestinationValid else {
            background?.setTaskCompleted(success: false); return
        }
        let permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard permission == .authorized || permission == .limited else {
            status = "No hay autorización de Fotos."
            background?.setTaskCompleted(success: false); return
        }
        if checkpoint.destination != destination {
            checkpoint = GalleryCheckpoint(destination: destination)
            completedIDs.removeAll(); saveCheckpoint()
        }
        backgroundTask = background
        stopRequested = false; uploaded = 0; failed = 0; inFlight = 0
        isRunning = true

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeHiddenAssets = true
        var all: [PHAsset] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in all.append(asset) }
        pending = all.filter { !completedIDs.contains($0.localIdentifier) }
        status = "\(pending.count) pendientes de \(all.count)."
        pump()
    }

    private func pump() {
        guard !stopRequested, enabled else { finish(success: false); return }
        while inFlight < maxConcurrent, !pending.isEmpty {
            let asset = pending.removeFirst()
            inFlight += 1
            upload(asset)
        }
        if inFlight == 0 && pending.isEmpty { finish(success: failed == 0) }
    }

    private func upload(_ asset: PHAsset) {
        guard let url = URL(string: destination),
              let resource = PHAssetResource.assetResources(for: asset).first else {
            done(asset, ok: false); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue(asset.localIdentifier, forHTTPHeaderField: "X-Photo-Asset-ID")
        request.setValue(resource.uniformTypeIdentifier, forHTTPHeaderField: "X-Photo-UTI")
        if let name = resource.originalFilename.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            request.setValue(name, forHTTPHeaderField: "X-Photo-Filename")
        }
        if let created = asset.creationDate {
            request.setValue(String(created.timeIntervalSince1970), forHTTPHeaderField: "X-Photo-Created")
        }
        if let location = asset.location {
            request.setValue("\(location.coordinate.latitude),\(location.coordinate.longitude)",
                             forHTTPHeaderField: "X-Photo-Coords")
        }
        let ext = (resource.originalFilename as NSString).pathExtension
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext.isEmpty ? "bin" : ext)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        resourceManager.writeData(for: resource, toFile: temp, options: options) { [weak self] error in
            guard let self = self else { return }
            guard error == nil else {
                try? FileManager.default.removeItem(at: temp)
                self.done(asset, ok: false); return
            }
            let task = URLSession.shared.uploadTask(with: request, fromFile: temp) { _, response, _ in
                try? FileManager.default.removeItem(at: temp)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                self.done(asset, ok: (200...299).contains(code))
            }
            task.resume()
        }
    }

    private func done(_ asset: PHAsset, ok: Bool) {
        DispatchQueue.main.async {
            self.inFlight -= 1
            if ok {
                if self.completedIDs.insert(asset.localIdentifier).inserted {
                    self.checkpoint.completedAssetIDs.append(asset.localIdentifier)
                }
                self.checkpoint.lastUpdated = Date()
                self.uploaded += 1
                if self.uploaded % 25 == 0 { self.saveCheckpoint() }
            } else {
                self.failed += 1
            }
            self.status = "Enviadas \(self.uploaded) · fallidas \(self.failed)."
            self.pump()
        }
    }

    private func saveCheckpoint() {
        if let data = try? JSONEncoder().encode(checkpoint) {
            try? data.write(to: checkpointURL, options: .atomic)
        }
    }

    private func finish(success: Bool) {
        guard isRunning else {
            backgroundTask?.setTaskCompleted(success: false)
            backgroundTask = nil
            return
        }
        isRunning = false
        saveCheckpoint()
        pending = []
        backgroundTask?.setTaskCompleted(success: success)
        backgroundTask = nil
        if enabled { scheduleIfEnabled() }
    }
}

// MARK: - Cámara

struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.image = info[.originalImage] as? UIImage
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

// MARK: - Pantallas

struct OnboardingView: View {
    @ObservedObject var permissions: PermissionCoordinator
    let completion: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Bienvenido a Comidas").font(.largeTitle.bold())
                Text("Registra tus comidas con foto y controla tus calorías. Cada permiso se pide en orden; puedes rechazar cualquiera.")
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(PermissionStep.allCases) { step in
                        HStack(alignment: .top) {
                            Image(systemName: step == permissions.currentStep ? "arrow.right.circle.fill" : "circle")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title)
                                if step == .photos {
                                    Text("Pulsa «Permitir acceso completo», no «Seleccionar fotos».")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .foregroundStyle(step == permissions.currentStep ? .primary : .secondary)
                    }
                }
                .padding(.vertical, 4)
                Text(permissions.status).font(.footnote)
                Spacer()
                if permissions.finished {
                    Button("Entrar a Comidas", action: completion)
                        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                } else {
                    Button(permissions.isRunning ? "Solicitando permisos…" : "Iniciar permisos") {
                        permissions.start()
                    }
                    .disabled(permissions.isRunning)
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
    }
}

struct MealListView: View {
    @ObservedObject var store: MealStore
    @State private var showAddMeal = false

    var body: some View {
        NavigationStack {
            List {
                if store.meals.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "fork.knife.circle").font(.largeTitle)
                        Text("Sin comidas").font(.headline)
                        Text("Registra tu primera comida con una foto.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(store.meals) { meal in
                        HStack(spacing: 12) {
                            if let thumb = store.thumbnail(for: meal) {
                                Image(uiImage: thumb).resizable().scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(meal.title).font(.headline)
                                if !meal.notes.isEmpty { Text(meal.notes).foregroundStyle(.secondary) }
                                if let kcal = meal.kcal {
                                    Text("\(kcal) kcal").font(.caption).foregroundStyle(.secondary)
                                }
                                Text(meal.date, format: .dateTime.day().month().year().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: store.delete)
                }
            }
            .navigationTitle("Comidas")
            .toolbar {
                Button { showAddMeal = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Añadir comida")
            }
            .sheet(isPresented: $showAddMeal) { AddMealView(store: store) }
        }
    }
}

struct AddMealView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: MealStore
    @State private var title = ""
    @State private var notes = ""
    @State private var date = Date()
    @State private var kcalText = ""
    @State private var photo: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Foto del plato") {
                    HStack(spacing: 14) {
                        Button { showCamera = true } label: {
                            Label("Hacer foto", systemImage: "camera")
                        }
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label("Elegir de galería", systemImage: "photo.on.rectangle")
                        }
                    }
                    if let photo {
                        Image(uiImage: photo).resizable().scaledToFit()
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                TextField("Nombre de la comida", text: $title)
                TextField("Calorías (opcional)", text: $kcalText).keyboardType(.numberPad)
                TextField("Notas", text: $notes, axis: .vertical).lineLimit(2...5)
                DatePicker("Fecha y hora", selection: $date)
            }
            .navigationTitle("Añadir comida")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        let file = photo.flatMap { store.savePhoto($0) }
                        store.add(title: title, notes: notes, date: date,
                                  photoFilename: file, kcal: Int(kcalText))
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showCamera) { CameraPicker(image: $photo).ignoresSafeArea() }
            .onChange(of: pickerItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) { photo = image }
                }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var gallery: GallerySync
    @ObservedObject var permissions: PermissionCoordinator

    var body: some View {
        NavigationStack {
            Form {
                Section("Permisos") {
                    Button("Solicitar los permisos pendientes") { permissions.requestMissing() }
                        .disabled(permissions.isRunning)
                    if gallery.isLimited {
                        Button("Ampliar acceso a fotos") { presentLimitedPicker() }
                    }
                    if permissions.isRunning { Text(permissions.status).font(.caption) }
                }
                Section("Sincronización de galería") {
                    TextField("Dirección del receptor", text: $gallery.destination)
                        .disabled(gallery.isRunning)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Autorizar sincronización de fotos y vídeos", isOn: $gallery.enabled)
                    Button("Sincronizar galería") { gallery.startFromUser() }
                        .disabled(!gallery.enabled || !gallery.isDestinationValid || gallery.isRunning)
                    Text(gallery.status).font(.footnote)
                    Button("Borrar historial de sincronización") { gallery.resetCheckpoint() }
                        .disabled(gallery.isRunning)
                }
            }
            .navigationTitle("Ajustes")
        }
    }

    private func presentLimitedPicker() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
    }
}

// MARK: - App

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: GallerySync.taskIdentifier, using: nil) { task in
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false); return
            }
            GallerySync.shared.handleBackgroundTask(processing)
        }
        return true
    }
}

@main
struct ComidasApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var meals = MealStore()
    @StateObject private var permissions = PermissionCoordinator()
    @StateObject private var gallery = GallerySync.shared
    @AppStorage("onboarding.completed") private var onboardingCompleted = false

    var body: some Scene {
        WindowGroup {
            Group {
                if onboardingCompleted {
                    TabView {
                        MealListView(store: meals)
                            .tabItem { Label("Comidas", systemImage: "fork.knife") }
                        SettingsView(gallery: gallery, permissions: permissions)
                            .tabItem { Label("Ajustes", systemImage: "gearshape") }
                    }
                } else {
                    OnboardingView(permissions: permissions) {
                        onboardingCompleted = true
                        gallery.scheduleIfEnabled()
                    }
                }
            }
            .onAppear { gallery.scheduleIfEnabled() }
        }
    }
}
