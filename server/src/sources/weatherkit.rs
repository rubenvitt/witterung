//! Apple WeatherKit REST API (`/api/v1/weather/{lang}/{lat}/{lon}`).
//!
//! Auth: an ES256 JWT signed with the WeatherKit `.p8` key; header carries
//! `kid` and `id` = "TEAM.SERVICE", claims `iss`, `iat`, `exp`, `sub`.
//! Units are metric (°C, km/h, mm, mbar); humidity, cloud cover and
//! precipitation chance come as 0–1. `forecastStart` is the hour start, so
//! nothing is shifted. The documented day object has no wind maximum.

use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use jiff::Timestamp;
use ring::rand::SystemRandom;
use ring::signature::{EcdsaKeyPair, ECDSA_P256_SHA256_FIXED_SIGNING};
use serde::Deserialize;
use serde_json::json;
use url::Url;

use super::{berlin, Condition, DayPoint, HourPoint, SourceData, SourceError, SourceId};

/// Hours requested: 48 h plus slack for the hour already running.
const HOURS: i64 = 50;

/// Credentials from the Apple Developer account. The key never leaves the
/// process; `Debug` hides it.
#[derive(Clone)]
pub struct WeatherKitConfig {
    pub key_pem: String,
    pub key_id: String,
    pub team_id: String,
    pub service_id: String,
}

impl std::fmt::Debug for WeatherKitConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WeatherKitConfig")
            .field("key_id", &self.key_id)
            .field("team_id", &self.team_id)
            .field("service_id", &self.service_id)
            .finish_non_exhaustive()
    }
}

impl WeatherKitConfig {
    fn key(&self) -> Result<EcdsaKeyPair, String> {
        let b64: String = self
            .key_pem
            .lines()
            .filter(|l| !l.starts_with("-----"))
            .collect();
        let der = STANDARD
            .decode(b64.trim())
            .map_err(|e| format!("WeatherKit-Schlüssel ist kein PEM: {e}"))?;
        EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &der, &SystemRandom::new())
            .map_err(|e| format!("WeatherKit-Schlüssel unbrauchbar: {e}"))
    }

    /// Fails early (at startup) on a broken key.
    pub fn validate(&self) -> Result<(), String> {
        self.key().map(|_| ())
    }

    pub fn token(&self, now: Timestamp) -> Result<String, SourceError> {
        let key = self.key().map_err(SourceError::Http)?;
        let header = json!({
            "alg": "ES256",
            "kid": self.key_id,
            "id": format!("{}.{}", self.team_id, self.service_id),
        });
        let iat = now.as_second();
        let claims = json!({
            "iss": self.team_id,
            "iat": iat,
            "exp": iat + 3600,
            "sub": self.service_id,
        });
        let input = format!(
            "{}.{}",
            URL_SAFE_NO_PAD.encode(header.to_string()),
            URL_SAFE_NO_PAD.encode(claims.to_string())
        );
        let sig = key
            .sign(&SystemRandom::new(), input.as_bytes())
            .map_err(|_| SourceError::Http("JWT-Signatur fehlgeschlagen".into()))?;
        Ok(format!("{input}.{}", URL_SAFE_NO_PAD.encode(sig.as_ref())))
    }
}

pub fn url(base: &Url, lat: f64, lon: f64, now: Timestamp) -> Result<Url, SourceError> {
    let mut url = base
        .join(&format!("weather/de/{lat}/{lon}"))
        .map_err(|e| SourceError::Http(e.to_string()))?;
    // Whole hours: fractional seconds in the query are not documented as valid.
    let hour = now.as_second().div_euclid(3600) * 3600;
    let end = Timestamp::from_second(hour + HOURS * 3600)
        .map_err(|e| SourceError::Http(e.to_string()))?;
    url.query_pairs_mut()
        .append_pair("dataSets", "forecastHourly,forecastDaily")
        .append_pair("timezone", "Europe/Berlin")
        .append_pair("countryCode", "DE")
        .append_pair("hourlyEnd", &end.to_string());
    Ok(url)
}

pub async fn fetch(
    http: &reqwest::Client,
    base: &Url,
    config: &WeatherKitConfig,
    lat: f64,
    lon: f64,
    now: Timestamp,
) -> Result<Vec<SourceData>, SourceError> {
    let response = http
        .get(url(base, lat, lon, now)?)
        .bearer_auth(config.token(now)?)
        .send()
        .await
        .map_err(|e| SourceError::Http(e.without_url().to_string()))?;
    let status = response.status();
    if !status.is_success() {
        return Err(SourceError::Http(format!("HTTP {status}")));
    }
    let body = response
        .bytes()
        .await
        .map_err(|e| SourceError::Http(e.without_url().to_string()))?;
    Ok(vec![parse(&body)?])
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Body {
    forecast_hourly: Option<Hours>,
    forecast_daily: Option<Days>,
}

#[derive(Deserialize)]
struct Hours {
    hours: Vec<Hour>,
}

#[derive(Deserialize)]
struct Days {
    days: Vec<Day>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Hour {
    forecast_start: Timestamp,
    temperature: Option<f64>,
    temperature_apparent: Option<f64>,
    precipitation_amount: Option<f64>,
    precipitation_chance: Option<f64>,
    wind_speed: Option<f64>,
    wind_gust: Option<f64>,
    wind_direction: Option<f64>,
    cloud_cover: Option<f64>,
    humidity: Option<f64>,
    pressure: Option<f64>,
    condition_code: String,
    daylight: Option<bool>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Day {
    forecast_start: Timestamp,
    temperature_max: Option<f64>,
    temperature_min: Option<f64>,
    precipitation_amount: Option<f64>,
    precipitation_chance: Option<f64>,
    condition_code: String,
    sunrise: Option<Timestamp>,
    sunset: Option<Timestamp>,
}

fn pct(v: Option<f64>) -> Option<f64> {
    v.map(|v| (v * 100.0).round())
}

pub fn parse(body: &[u8]) -> Result<SourceData, SourceError> {
    let body: Body = serde_json::from_slice(body).map_err(|e| SourceError::Parse(e.to_string()))?;
    let (Some(hours), Some(days)) = (body.forecast_hourly, body.forecast_daily) else {
        return Err(SourceError::Parse(
            "forecastHourly oder forecastDaily fehlt".into(),
        ));
    };
    let hourly = hours
        .hours
        .into_iter()
        .filter_map(|h| {
            Some(HourPoint {
                at: h.forecast_start,
                temp_c: h.temperature?,
                feels_like_c: h.temperature_apparent,
                precip_mm: h.precipitation_amount?,
                precip_prob_pct: pct(h.precipitation_chance),
                wind_kmh: h.wind_speed?,
                gust_kmh: h.wind_gust,
                wind_dir_deg: h.wind_direction,
                cloud_pct: pct(h.cloud_cover),
                humidity_pct: pct(h.humidity),
                pressure_hpa: h.pressure,
                condition: condition(&h.condition_code)?,
                is_day: h.daylight,
            })
        })
        .collect();
    let tz = berlin();
    let daily = days
        .days
        .into_iter()
        .filter_map(|d| {
            Some(DayPoint {
                date: d.forecast_start.to_zoned(tz.clone()).date(),
                temp_min_c: d.temperature_min?,
                temp_max_c: d.temperature_max?,
                precip_mm: d.precipitation_amount?,
                precip_prob_pct: pct(d.precipitation_chance),
                wind_max_kmh: None,
                gust_max_kmh: None,
                condition: condition(&d.condition_code)?,
                sunrise: d.sunrise,
                sunset: d.sunset,
            })
        })
        .collect();
    Ok(SourceData {
        source: SourceId::WeatherKit,
        hourly,
        daily,
    })
}

/// `WeatherCondition` codes. Unknown codes yield `None` (the point is
/// dropped rather than guessed).
pub fn condition(code: &str) -> Option<Condition> {
    use Condition::*;
    Some(match code {
        "Clear" | "MostlyClear" | "Hot" | "Frigid" => Clear,
        "PartlyCloudy" => PartlyCloudy,
        "MostlyCloudy" | "Cloudy" => Cloudy,
        "Foggy" | "Haze" | "Smoky" => Fog,
        "Breezy" | "Windy" | "BlowingDust" => Wind,
        "Drizzle" => Drizzle,
        "Rain" | "SunShowers" => Rain,
        "HeavyRain" => HeavyRain,
        "Flurries" | "SunFlurries" | "Snow" | "HeavySnow" | "BlowingSnow" | "Blizzard" => Snow,
        "Sleet" | "WintryMix" | "FreezingDrizzle" | "FreezingRain" => Sleet,
        "Hail" => Hail,
        "IsolatedThunderstorms"
        | "ScatteredThunderstorms"
        | "Thunderstorms"
        | "StrongStorms"
        | "Hurricane"
        | "TropicalStorm" => Thunderstorm,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use jiff::civil::date;
    use ring::signature::{KeyPair, UnparsedPublicKey, ECDSA_P256_SHA256_FIXED};

    // Synthetic: built from the documented schema, no real response yet.
    const FIXTURE: &[u8] = include_bytes!("../../tests/fixtures/weatherkit/weather.json");

    #[test]
    fn parses_documented_schema() {
        let data = parse(FIXTURE).unwrap();
        assert_eq!(data.hourly.len(), 3);
        let h = &data.hourly[0];
        assert_eq!(h.at.to_string(), "2026-11-10T08:00:00Z");
        assert_eq!(h.temp_c, 6.1);
        assert_eq!(h.wind_kmh, 14.0);
        assert_eq!(h.cloud_pct, Some(97.0));
        assert_eq!(h.precip_prob_pct, Some(12.0));
        assert_eq!(h.condition, Condition::Cloudy);
        assert_eq!(h.is_day, Some(true));
        let d = &data.daily[0];
        // forecastStart 23:00Z = midnight in Berlin.
        assert_eq!(d.date, date(2026, 11, 10));
        assert_eq!((d.temp_min_c, d.temp_max_c), (3.8, 8.1));
        assert_eq!(d.condition, Condition::Drizzle);
        assert_eq!(d.wind_max_kmh, None);
        assert!(d.sunrise.is_some());
    }

    #[test]
    fn unknown_condition_drops_the_point() {
        let mut v: serde_json::Value = serde_json::from_slice(FIXTURE).unwrap();
        v["forecastHourly"]["hours"][0]["conditionCode"] = "Volcano".into();
        let data = parse(&serde_json::to_vec(&v).unwrap()).unwrap();
        assert_eq!(data.hourly.len(), 2);
    }

    #[test]
    fn jwt_has_weatherkit_header_and_valid_signature() {
        let rng = SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
        let pem = format!(
            "-----BEGIN PRIVATE KEY-----\n{}\n-----END PRIVATE KEY-----\n",
            STANDARD.encode(pkcs8.as_ref())
        );
        let config = WeatherKitConfig {
            key_pem: pem,
            key_id: "ABC123DEFG".into(),
            team_id: "TEAM123456".into(),
            service_id: "dev.example.witterung".into(),
        };
        config.validate().unwrap();
        let now: Timestamp = "2026-11-09T12:00:00Z".parse().unwrap();
        let token = config.token(now).unwrap();
        let parts: Vec<&str> = token.split('.').collect();
        let header: serde_json::Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[0]).unwrap()).unwrap();
        assert_eq!(header["alg"], "ES256");
        assert_eq!(header["kid"], "ABC123DEFG");
        assert_eq!(header["id"], "TEAM123456.dev.example.witterung");
        let claims: serde_json::Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[1]).unwrap()).unwrap();
        assert_eq!(claims["iss"], "TEAM123456");
        assert_eq!(claims["sub"], "dev.example.witterung");
        assert_eq!(claims["exp"], now.as_second() + 3600);

        let public =
            EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng)
                .unwrap()
                .public_key()
                .as_ref()
                .to_vec();
        let sig = URL_SAFE_NO_PAD.decode(parts[2]).unwrap();
        UnparsedPublicKey::new(&ECDSA_P256_SHA256_FIXED, public)
            .verify(format!("{}.{}", parts[0], parts[1]).as_bytes(), &sig)
            .expect("signature verifies");
        assert!(format!("{config:?}").contains("ABC123DEFG"));
        assert!(!format!("{config:?}").contains("PRIVATE"));
    }

    #[test]
    fn url_has_whole_hour_end() {
        let base = Url::parse("https://weatherkit.apple.com/api/v1/").unwrap();
        let now: Timestamp = "2026-11-09T11:36:57.289214Z".parse().unwrap();
        let url = url(&base, 52.9656, 10.5594, now).unwrap();
        assert_eq!(url.path(), "/api/v1/weather/de/52.9656/10.5594");
        let q: Vec<(String, String)> = url.query_pairs().into_owned().collect();
        assert!(q.contains(&("hourlyEnd".into(), "2026-11-11T13:00:00Z".into())));
        assert!(q.contains(&("timezone".into(), "Europe/Berlin".into())));
    }

    #[test]
    fn broken_key_is_rejected() {
        let config = WeatherKitConfig {
            key_pem: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----".into(),
            key_id: "k".into(),
            team_id: "t".into(),
            service_id: "s".into(),
        };
        assert!(config.validate().is_err());
    }
}
