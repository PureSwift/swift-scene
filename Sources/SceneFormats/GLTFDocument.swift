import Foundation

// Core glTF 2.0 schema. Optional arrays follow the specification's empty-array defaults.
struct GLTFDocument: Decodable {
    struct Asset: Decodable { var version: String; var minVersion: String? }
    struct Buffer: Decodable { var uri: String?; var byteLength: Int }
    struct BufferView: Decodable { var buffer: Int; var byteOffset: Int?; var byteLength: Int; var byteStride: Int? }
    struct Accessor: Decodable {
        struct Sparse: Decodable {
            struct Indices: Decodable { var bufferView: Int; var byteOffset: Int?; var componentType: Int }
            struct Values: Decodable { var bufferView: Int; var byteOffset: Int? }
            var count: Int; var indices: Indices; var values: Values
        }
        var bufferView: Int?; var byteOffset: Int?; var componentType: Int
        var normalized: Bool?; var count: Int; var type: String; var sparse: Sparse?
    }
    struct Primitive: Decodable {
        var attributes: [String: Int]; var indices: Int?; var material: Int?; var mode: Int?
        var targets: [[String: Int]]?
    }
    struct Mesh: Decodable { var name: String?; var primitives: [Primitive]; var weights: [Float]? }
    struct Node: Decodable {
        struct Extensions: Decodable {
            struct PunctualLight: Decodable { var light: Int }
            var KHR_lights_punctual: PunctualLight?
        }
        var extensions: Extensions?
        var name: String?; var children: [Int]?; var mesh: Int?; var skin: Int?; var camera: Int?
        var matrix: [Float]?; var translation: [Float]?; var rotation: [Float]?; var scale: [Float]?
        var weights: [Float]?
    }
    struct Scene: Decodable { var name: String?; var nodes: [Int]? }
    struct Skin: Decodable { var name: String?; var joints: [Int]; var inverseBindMatrices: Int?; var skeleton: Int? }
    struct TextureInfo: Decodable { var index: Int; var texCoord: Int?; var scale: Float?; var strength: Float? }
    struct PBR: Decodable {
        var baseColorFactor: [Float]?; var baseColorTexture: TextureInfo?
        var metallicFactor: Float?; var roughnessFactor: Float?; var metallicRoughnessTexture: TextureInfo?
    }
    struct Material: Decodable {
        struct Extensions: Decodable {
            struct Unlit: Decodable {}
            struct EmissiveStrength: Decodable { var emissiveStrength: Float? }
            var KHR_materials_emissive_strength: EmissiveStrength?
            var KHR_materials_unlit: Unlit?
        }
        var extensions: Extensions?
        var name: String?; var pbrMetallicRoughness: PBR?; var normalTexture: TextureInfo?
        var occlusionTexture: TextureInfo?; var emissiveTexture: TextureInfo?; var emissiveFactor: [Float]?
        var alphaMode: String?; var alphaCutoff: Float?; var doubleSided: Bool?
    }
    struct Texture: Decodable { var sampler: Int?; var source: Int? }
    struct Image: Decodable { var uri: String?; var mimeType: String?; var bufferView: Int? }
    struct Sampler: Decodable { var magFilter: Int?; var minFilter: Int?; var wrapS: Int?; var wrapT: Int? }
    struct Camera: Decodable {
        struct Perspective: Decodable { var yfov: Float; var znear: Float; var zfar: Float?; var aspectRatio: Float? }
        struct Orthographic: Decodable { var xmag: Float; var ymag: Float; var zfar: Float; var znear: Float }
        var name: String?; var type: String; var perspective: Perspective?; var orthographic: Orthographic?
    }
    struct Animation: Decodable {
        struct Sampler: Decodable { var input: Int; var output: Int; var interpolation: String? }
        struct Channel: Decodable {
            struct Target: Decodable { var node: Int?; var path: String }
            var sampler: Int; var target: Target
        }
        var name: String?; var samplers: [Sampler]; var channels: [Channel]
    }
    var asset: Asset; var buffers: [Buffer]?; var bufferViews: [BufferView]?; var accessors: [Accessor]?
    var meshes: [Mesh]?; var nodes: [Node]?; var scenes: [Scene]?; var scene: Int?
    var materials: [Material]?; var textures: [Texture]?; var images: [Image]?; var samplers: [Sampler]?
    var skins: [Skin]?; var animations: [Animation]?; var cameras: [Camera]?
    struct PunctualLight: Decodable {
        struct Spot: Decodable { var innerConeAngle: Float?; var outerConeAngle: Float? }
        var name: String?; var type: String; var color: [Float]?; var intensity: Float?
        var range: Float?; var spot: Spot?
    }
    struct Extensions: Decodable {
        struct PunctualLights: Decodable { var lights: [PunctualLight] }
        var KHR_lights_punctual: PunctualLights?
    }
    var extensions: Extensions?
    var extensionsRequired: [String]?
}
