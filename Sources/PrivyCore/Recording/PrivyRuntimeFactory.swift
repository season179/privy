import Foundation

/// Composes the production shadow-capture graph behind PrivyCore's public contracts.
///
/// The caller must finish Store migration and reconciliation before constructing the
/// controller, and owns calling `start()` and `shutdown()`. The returned pipeline is the
/// sole owner of capture, writer, VAD, and their long-lived tasks.
public enum PrivyRuntimeFactory {
    public static func makeShadowCaptureController(
        store: any PrivyStoring,
        storage: StorageLayout,
        clock: any PrivyClock
    ) -> any ShadowCaptureControlling {
        let capture = CaptureEngine(clock: clock)
        let writer = ShadowChunkWriter(store: store, storage: storage)
        // Loading remains deferred until VADService.prepare(), where it runs detached from
        // the caller actor. Model failure degrades VAD only and never blocks capture startup.
        let vad = VADService(config: .default) {
            try await FluidAudioVADAdapter.load()
        }
        return ShadowCapturePipeline(
            capture: capture,
            writer: writer,
            vad: vad,
            store: store,
            clock: clock
        )
    }
}
