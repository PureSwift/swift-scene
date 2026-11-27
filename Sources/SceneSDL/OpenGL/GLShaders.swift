// The one program every draw uses: Blinn, Phong, Lambert, unlit, and an approximation of metallic-roughness
// shading, with up to `maxLights` ambient, directional, omni and spot lights. Colours are linear; textures are
// read as sRGB, and the result is written as sRGB.

enum GLShaders {

    static let maxLights = 8

    // Where the vertex streams are bound.
    static let positionLocation: GLuint = 0
    static let normalLocation: GLuint = 1
    static let textureCoordinateLocation: GLuint = 2
    static let colorLocation: GLuint = 3
    static let textureCoordinate1Location: GLuint = 4
    static let tangentLocation: GLuint = 5

    /// The version line and precision for the context's flavour of GLSL.
    static func header(isES: Bool) -> String {
        isES ? "#version 300 es\nprecision highp float;\nprecision highp int;\n" : "#version 330 core\n"
    }

    static let vertex = """
    in vec3 a_position;
    in vec3 a_normal;
    in vec2 a_textureCoordinate;
    in vec2 a_textureCoordinate1;
    in vec4 a_color;
    in vec4 a_tangent;

    uniform mat4 u_model;
    uniform mat4 u_viewProjection;
    uniform mat4 u_normalMatrix;
    uniform mat4 u_textureTransform;

    out vec3 v_worldPosition;
    out vec3 v_normal;
    out vec2 v_textureCoordinate;
    out vec2 v_textureCoordinate1;
    out vec4 v_color;
    out vec4 v_tangent;

    void main() {
        vec4 world = u_model * vec4(a_position, 1.0);
        v_worldPosition = world.xyz;
        v_normal = mat3(u_normalMatrix) * a_normal;
        v_textureCoordinate = (u_textureTransform * vec4(a_textureCoordinate, 0.0, 1.0)).xy;
        v_textureCoordinate1 = a_textureCoordinate1;
        v_color = a_color;
        v_tangent = vec4(mat3(u_model) * a_tangent.xyz, a_tangent.w * sign(determinant(mat3(u_model))));
        gl_Position = u_viewProjection * world;
    }
    """

    static let fragment = """
    #define MAX_LIGHTS \(maxLights)

    in vec3 v_worldPosition;
    in vec3 v_normal;
    in vec2 v_textureCoordinate;
    in vec2 v_textureCoordinate1;
    in vec4 v_color;
    in vec4 v_tangent;

    // 0 physically based, 1 Blinn, 2 Phong, 3 Lambert, 4 unlit.
    uniform int u_lightingModel;
    uniform vec4 u_diffuse;
    uniform int u_hasDiffuseTexture;
    uniform sampler2D u_diffuseTexture;
    uniform vec3 u_ambient;
    uniform vec3 u_specular;
    uniform vec3 u_emission;
    uniform float u_shininess;
    uniform float u_metalness;
    uniform float u_roughness;
    uniform float u_opacity;
    uniform int u_isDoubleSided;
    uniform vec3 u_cameraPosition;
    uniform int u_alphaMode;
    uniform float u_alphaCutoff;
    uniform int u_diffuseChannel;
    uniform int u_hasMetallicRoughnessTexture;
    uniform sampler2D u_metallicRoughnessTexture;
    uniform int u_metallicRoughnessChannel;
    uniform int u_hasNormalTexture;
    uniform sampler2D u_normalTexture;
    uniform int u_normalChannel;
    uniform float u_normalScale;
    uniform int u_hasOcclusionTexture;
    uniform sampler2D u_occlusionTexture;
    uniform int u_occlusionChannel;
    uniform float u_occlusionStrength;
    uniform int u_hasEmissionTexture;
    uniform sampler2D u_emissionTexture;
    uniform int u_emissionChannel;

    vec2 uv(int channel) {
        return channel == 1 ? v_textureCoordinate1 : v_textureCoordinate;
    }

    // 0 ambient, 1 directional, 2 omni, 3 spot.
    uniform int u_lightCount;
    uniform int u_lightType[MAX_LIGHTS];
    uniform vec3 u_lightColor[MAX_LIGHTS];
    uniform vec3 u_lightPosition[MAX_LIGHTS];
    uniform vec3 u_lightDirection[MAX_LIGHTS];
    // Attenuation start, end and falloff exponent.
    uniform vec3 u_lightAttenuation[MAX_LIGHTS];
    // The cosines of a spot's inner and outer half angles.
    uniform vec2 u_lightSpot[MAX_LIGHTS];

    out vec4 o_color;

    void main() {
        vec4 base = u_diffuse * v_color;
        if (u_hasDiffuseTexture != 0) {
            vec4 texel = texture(u_diffuseTexture, uv(u_diffuseChannel));
            base *= vec4(pow(texel.rgb, vec3(2.2)), texel.a);
        }
        float alpha = base.a * u_opacity;
        if (u_alphaMode == 1) alpha = 1.0;
        if (u_alphaMode == 2) {
            if (alpha < u_alphaCutoff) discard;
            alpha = 1.0;
        }
        vec3 emission = u_emission;
        if (u_hasEmissionTexture != 0) emission *= pow(texture(u_emissionTexture, uv(u_emissionChannel)).rgb, vec3(2.2));
        float metalness = u_metalness;
        float roughness = u_roughness;
        if (u_hasMetallicRoughnessTexture != 0) {
            vec4 mr = texture(u_metallicRoughnessTexture, uv(u_metallicRoughnessChannel));
            metalness *= mr.b;
            roughness *= mr.g;
        }
        float occlusion = 1.0;
        if (u_hasOcclusionTexture != 0) occlusion = mix(1.0, texture(u_occlusionTexture, uv(u_occlusionChannel)).r, u_occlusionStrength);
        if (u_lightingModel == 4) {
            o_color = vec4(pow(base.rgb + emission, vec3(1.0 / 2.2)), alpha);
            return;
        }

        vec3 n = normalize(v_normal);
        if (u_hasNormalTexture != 0) {
            vec2 st = uv(u_normalChannel);
            vec3 q1 = dFdx(v_worldPosition), q2 = dFdy(v_worldPosition);
            vec2 st1 = dFdx(st), st2 = dFdy(st);
            float determinant = st1.x * st2.y - st1.y * st2.x;
            if (dot(v_tangent.xyz, v_tangent.xyz) > 1e-8 || abs(determinant) > 1e-8) {
                bool supplied = dot(v_tangent.xyz, v_tangent.xyz) > 1e-8;
                vec3 t = supplied ? v_tangent.xyz : (q1 * st2.y - q2 * st1.y) / determinant;
                t = normalize(t - n * dot(n, t));
                vec3 b = normalize(cross(n, t)) * (supplied ? v_tangent.w : sign(determinant));
                vec3 sampleNormal = texture(u_normalTexture, st).xyz * 2.0 - 1.0;
                sampleNormal.xy *= u_normalScale;
                n = normalize(mat3(t, b, n) * sampleNormal);
            }
        }
        if (u_isDoubleSided != 0 && !gl_FrontFacing) n = -n;
        vec3 v = normalize(u_cameraPosition - v_worldPosition);

        vec3 diffuseColor = base.rgb;
        vec3 specularColor = u_specular;
        float exponent = max(u_shininess * 128.0, 1.0);
        if (u_lightingModel == 0) {
            diffuseColor = base.rgb * (1.0 - metalness);
            specularColor = mix(vec3(0.04), base.rgb, metalness);
            float r = clamp(roughness, 0.05, 1.0);
            exponent = clamp(2.0 / (r * r * r * r) - 2.0, 1.0, 2048.0);
        }

        vec3 color = u_ambient * diffuseColor * occlusion + emission;
        for (int i = 0; i < MAX_LIGHTS; i++) {
            if (i >= u_lightCount) break;
            int type = u_lightType[i];
            if (type == 0) {
                // A physically based surface also reflects ambient light off its specular colour: a stand-in for
                // the environment lighting that metals take their colour from.
                vec3 reflected = u_lightingModel == 0 ? specularColor * (1.0 - 0.5 * roughness) : vec3(0.0);
                color += u_lightColor[i] * (diffuseColor + reflected) * occlusion;
                continue;
            }
            vec3 l;
            float attenuation = 1.0;
            if (type == 1) {
                l = -u_lightDirection[i];
            } else {
                vec3 toLight = u_lightPosition[i] - v_worldPosition;
                float d = length(toLight);
                l = toLight / max(d, 1e-5);
                vec3 a = u_lightAttenuation[i];
                if (a.y > a.x) {
                    attenuation = pow(clamp((a.y - d) / (a.y - a.x), 0.0, 1.0), a.z);
                }
                if (type == 3) {
                    float c = dot(-l, u_lightDirection[i]);
                    attenuation *= smoothstep(u_lightSpot[i].y, u_lightSpot[i].x, c);
                }
            }
            float lambert = max(dot(n, l), 0.0);
            vec3 radiance = u_lightColor[i] * attenuation;
            color += radiance * diffuseColor * lambert;
            if (u_lightingModel != 3 && lambert > 0.0) {
                float highlight;
                if (u_lightingModel == 2) {
                    highlight = pow(max(dot(reflect(-l, n), v), 0.0), exponent);
                } else {
                    highlight = pow(max(dot(n, normalize(l + v)), 0.0), exponent);
                }
                color += radiance * specularColor * highlight;
            }
        }
        o_color = vec4(pow(max(color, vec3(0.0)), vec3(1.0 / 2.2)), alpha);
    }
    """
}
