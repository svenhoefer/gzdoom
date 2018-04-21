
const float PI = 3.14159265359;

float DistributionGGX(vec3 N, vec3 H, float roughness)
{
	float a = roughness * roughness;
	float a2 = a * a;
	float NdotH = max(dot(N, H), 0.0);
	float NdotH2 = NdotH*NdotH;

	float nom = a2;
	float denom = (NdotH2 * (a2 - 1.0) + 1.0);
	denom = PI * denom * denom;

	return nom / denom;
}

float GeometrySchlickGGX(float NdotV, float roughness)
{
	float r = (roughness + 1.0);
	float k = (r * r) / 8.0;

	float nom = NdotV;
	float denom = NdotV * (1.0 - k) + k;

	return nom / denom;
}

float GeometrySmith(vec3 N, vec3 V, vec3 L, float roughness)
{
	float NdotV = max(dot(N, V), 0.0);
	float NdotL = max(dot(N, L), 0.0);
	float ggx2 = GeometrySchlickGGX(NdotV, roughness);
	float ggx1 = GeometrySchlickGGX(NdotL, roughness);
	return ggx1 * ggx2;
}

vec3 fresnelSchlick(float cosTheta, vec3 F0)
{
	return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}

vec3 fresnelSchlickRoughness(float cosTheta, vec3 F0, float roughness)
{
	return F0 + (max(vec3(1.0 - roughness), F0) - F0) * pow(1.0 - cosTheta, 5.0);
}

float quadraticDistanceAttenuation(vec4 lightpos)
{
	float strength = (1.0 + lightpos.w * lightpos.w * 0.25) * 0.5;

	vec3 distVec = lightpos.xyz - pixelpos.xyz;
	float attenuation = strength / (1.0 + dot(distVec, distVec));
	if (attenuation <= 1.0 / 256.0) return 0.0;

	return attenuation;
}

vec3 ProcessMaterial(vec3 albedo, vec3 ambientLight)
{
	vec3 worldpos = pixelpos.xyz;

	albedo = pow(albedo, vec3(2.2)); // sRGB to linear
	ambientLight = pow(ambientLight, vec3(2.2));

	float metallic = texture(metallictexture, vTexCoord.st).r;
	float roughness = texture(roughnesstexture, vTexCoord.st).r;
	float ao = texture(aotexture, vTexCoord.st).r;

	vec3 N = ApplyNormalMap();
	vec3 V = normalize(uCameraPos.xyz - worldpos);

	vec3 F0 = mix(vec3(0.04), albedo, metallic);

	vec3 Lo = uDynLightColor.rgb;
	vec3 envWest = vec3(0.0);
	vec3 envEast = vec3(0.0);
	vec3 envNorth = vec3(0.0);
	vec3 envSouth = vec3(0.0);

	if (uLightIndex >= 0)
	{
		ivec4 lightRange = ivec4(lights[uLightIndex]) + ivec4(uLightIndex + 1);
		if (lightRange.z > lightRange.x)
		{
			//
			// modulated lights
			//
			for(int i=lightRange.x; i<lightRange.y; i+=4)
			{
				vec4 lightpos = lights[i];
				vec4 lightcolor = lights[i+1];
				vec4 lightspot1 = lights[i+2];
				vec4 lightspot2 = lights[i+3];

				if (lightcolor.a < 0.0) // Attenuated lights act as true point lights
				{
					vec3 L = normalize(lightpos.xyz - worldpos);
					vec3 H = normalize(V + L);

					float attenuation = quadraticDistanceAttenuation(lightpos);
					if (lightspot1.w == 1.0)
						attenuation *= spotLightAttenuation(lightpos, lightspot1.xyz, lightspot2.x, lightspot2.y);
					if (lightcolor.a < 0.0)
						attenuation *= clamp(dot(N, L), 0.0, 1.0); // Sign bit is the attenuated light flag

					if (attenuation > 0.0)
					{
						attenuation *= shadowAttenuation(lightpos, lightcolor.a);

						vec3 radiance = lightcolor.rgb * attenuation;

						// cook-torrance brdf
						float NDF = DistributionGGX(N, H, roughness);
						float G = GeometrySmith(N, V, L, roughness);
						vec3 F = fresnelSchlick(clamp(dot(H, V), 0.0, 1.0), F0);

						vec3 kS = F;
						vec3 kD = (vec3(1.0) - kS) * (1.0 - metallic);

						vec3 nominator = NDF * G * F;
						float denominator = 4.0 * clamp(dot(N, V), 0.0, 1.0) * clamp(dot(N, L), 0.0, 1.0);
						vec3 specular = nominator / max(denominator, 0.001);

						Lo += (kD * albedo / PI + specular) * radiance;
					}
				}
				else // Non-attenuated lights act as environmental lights
				{
					float lightdistance = distance(lightpos.xyz, pixelpos.xyz);
					float attenuation = clamp((lightpos.w - lightdistance) / lightpos.w, 0.0, 1.0);
					vec3 L = normalize(lightpos.xyz - worldpos);

					float cx = L.x * attenuation;
					float cz = L.z * attenuation;
					envEast += lightcolor.rgb * clamp(cx, 0.0, 1.0);
					envWest += lightcolor.rgb * clamp(-cx, 0.0, 1.0);
					envNorth += lightcolor.rgb * clamp(cz, 0.0, 1.0);
					envSouth += lightcolor.rgb * clamp(-cz, 0.0, 1.0);
				}
			}
			//
			// subtractive lights
			//
			for(int i=lightRange.y; i<lightRange.z; i+=4)
			{
				vec4 lightpos = lights[i];
				vec4 lightcolor = lights[i+1];
				vec4 lightspot1 = lights[i+2];
				vec4 lightspot2 = lights[i+3];
				
				vec3 L = normalize(lightpos.xyz - worldpos);
				vec3 H = normalize(V + L);

				float attenuation = quadraticDistanceAttenuation(lightpos);
				if (lightspot1.w == 1.0)
					attenuation *= spotLightAttenuation(lightpos, lightspot1.xyz, lightspot2.x, lightspot2.y);
				if (lightcolor.a < 0.0)
					attenuation *= clamp(dot(N, L), 0.0, 1.0); // Sign bit is the attenuated light flag

				if (attenuation > 0.0)
				{
					attenuation *= shadowAttenuation(lightpos, lightcolor.a);

					vec3 radiance = lightcolor.rgb * attenuation;

					// cook-torrance brdf
					float NDF = DistributionGGX(N, H, roughness);
					float G = GeometrySmith(N, V, L, roughness);
					vec3 F = fresnelSchlick(clamp(dot(H, V), 0.0, 1.0), F0);

					vec3 kS = F;
					vec3 kD = (vec3(1.0) - kS) * (1.0 - metallic);

					vec3 nominator = NDF * G * F;
					float denominator = 4.0 * clamp(dot(N, V), 0.0, 1.0) * clamp(dot(N, L), 0.0, 1.0);
					vec3 specular = nominator / max(denominator, 0.001);

					Lo -= (kD * albedo / PI + specular) * radiance;
				}
			}
		}
	}

	// Calculate environmental light contribution using four directional colors:

	// To do: add ambientLight 

	vec3 F = fresnelSchlickRoughness(clamp(dot(N, V), 0.0, 1.0), F0, roughness);

	vec3 kS = F;
	vec3 kD = 1.0 - kS;
	kD *= 1.0 - metallic;

	const float MAX_REFLECTION_LOD = 4.0;
	vec3 R = reflect(-V, N);
	vec4 irradianceData = texture(IrradianceMap, N);
	vec4 prefilterData = textureLod(PrefilterMap, R, roughness * MAX_REFLECTION_LOD);

	vec3 irradiance = irradianceData.x * envEast + irradianceData.y * envWest + irradianceData.z * envNorth + irradianceData.w * envSouth;
	vec3 diffuse = irradiance * albedo;

	vec3 prefilteredColor = prefilterData.x * envEast + prefilterData.y * envWest + prefilterData.z * envNorth + prefilterData.w * envSouth;
	vec2 envBRDF = texture(BrdfLUT, vec2(clamp(dot(N, V), 0.0, 1.0), roughness)).rg;
	vec3 specular = prefilteredColor * (F * envBRDF.x + envBRDF.y);

	vec3 ambient = (kD * diffuse + specular) * ao;

	vec3 color = max(ambient + Lo, vec3(0.0));

	// Tonemap (reinhard) and apply sRGB gamma
	//color = color / (color + vec3(1.0));
	return pow(color, vec3(1.0 / 2.2));
}
