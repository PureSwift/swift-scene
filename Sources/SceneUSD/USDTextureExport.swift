import SceneCore
import SceneFormats

/// Validated texture inputs. PNG bytes keep their original top-to-bottom row order;
/// the mesh exporter changes UV V to USD's bottom-origin convention.
struct USDTextureExport {
    let image: ImageBuffer
    let wrapS: String
    let wrapT: String

    init(_ property: MaterialProperty) throws(SceneFormatError) {
        guard case .texture(let source) = property.contents else {
            throw .unsupported("USDZ texture source required")
        }
        guard property.mappingChannel == 0, property.contentsTransform == .identity, property.intensity == 1 else {
            throw .unsupported("USDZ textures require UV0, identity texture transform and unit intensity")
        }
        let sampler = property.sampler
        guard sampler.minificationFilter == .linear, sampler.magnificationFilter == .linear,
              sampler.maxAnisotropy == 1 else {
            throw .unsupported("USDZ texture filtering requires linear filters and unit anisotropy")
        }
        // USD Preview Surface leaves mip filtering to the consuming renderer.
        guard sampler.mipFilter == .none || sampler.mipFilter == .linear else {
            throw .unsupported("USDZ nearest-mip texture filtering")
        }
        guard let image = TextureImageLoader.load(source) else {
            throw .unsupported("Cannot resolve USDZ texture")
        }
        self.image = image
        wrapS = Self.wrap(sampler.wrapS)
        wrapT = Self.wrap(sampler.wrapT)
    }

    private static func wrap(_ mode: TextureWrapMode) -> String {
        switch mode {
        case .clamp: "clamp"
        case .repeat: "repeat"
        case .mirror: "mirror"
        case .clampToBorder: "black"
        }
    }
}
