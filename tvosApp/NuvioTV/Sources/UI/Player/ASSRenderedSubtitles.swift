import Combine
import SwiftAssRenderer
import SwiftUI

/// Renders authored ASS/SSA frames over Aether's video surface.
struct ASSRenderedSubtitles: UIViewRepresentable {
    let renderer: AssSubtitlesRenderer
    let reloadSignal: PassthroughSubject<ASSRenderCoordinator.ReloadEvent, Never>
    let sourceTime: Double
    let onCanvasSizeChanged: ((AssSubtitlesRenderer) -> Void)?

    func makeUIView(context: Context) -> ASSFrameHostView {
        ASSFrameHostView(
            renderer: renderer,
            reloadSignal: reloadSignal,
            onCanvasSizeChanged: onCanvasSizeChanged
        )
    }

    func updateUIView(_ view: ASSFrameHostView, context: Context) {
        view.sourceTime = sourceTime
    }
}

/// Keeps the last frame during a track reload; libass briefly publishes nil
/// while reparsing even when a visible cue has not ended.
@MainActor
final class ASSFrameHostView: UIView {
    var sourceTime: Double = 0

    private let renderer: AssSubtitlesRenderer
    private let onCanvasSizeChanged: ((AssSubtitlesRenderer) -> Void)?
    private let imageView = UIImageView()
    private var displayScale: CGFloat {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        return scale > 0 ? scale : 1.0
    }
    private var previousBounds = CGRect.zero
    private var cancellables = Set<AnyCancellable>()
    private var isReloading = false
    private var previousCanvasSize = CGSize.zero
    private var previousDisplayScale: CGFloat = 0

    init(
        renderer: AssSubtitlesRenderer,
        reloadSignal: PassthroughSubject<ASSRenderCoordinator.ReloadEvent, Never>,
        onCanvasSizeChanged: ((AssSubtitlesRenderer) -> Void)?
    ) {
        self.renderer = renderer
        self.onCanvasSizeChanged = onCanvasSizeChanged
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        imageView.isUserInteractionEnabled = false
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        reloadSignal
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .began:
                    self.isReloading = true
                case .finished(let image):
                    self.isReloading = false
                    self.display(image)
                }
            }
            .store(in: &cancellables)
        renderer.framesPublisher()
            .sink { [weak self] image in self?.display(image) }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !bounds.isEmpty else { return }
        if !previousBounds.isEmpty, imageView.image != nil, previousBounds != bounds {
            let old = imageView.frame
            imageView.frame = CGRect(
                x: old.minX * bounds.width / previousBounds.width,
                y: old.minY * bounds.height / previousBounds.height,
                width: old.width * bounds.width / previousBounds.width,
                height: old.height * bounds.height / previousBounds.height
            ).integral
        }
        let scale = displayScale
        let canvasChanged = previousCanvasSize != bounds.size || previousDisplayScale != scale
        renderer.setCanvasSize(bounds.size, scale: scale)
        if canvasChanged {
            previousCanvasSize = bounds.size
            previousDisplayScale = scale
            onCanvasSizeChanged?(renderer)
        }
    }

    private func display(_ image: ProcessedImage?) {
        if let image {
            guard !isReloading else { return }
            isReloading = false
            previousBounds = bounds
            imageView.frame = image.imageRect
            imageView.image = UIImage(cgImage: image.image, scale: displayScale, orientation: .up)
            imageView.isHidden = false
            return
        }

        guard !isReloading else { return }
        hide()
    }

    private func hide() {
        isReloading = false
        imageView.image = nil
        imageView.isHidden = true
    }
}
