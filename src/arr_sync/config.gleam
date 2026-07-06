import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import simplifile
import tom.{type Toml}

pub type QbittorrentConfig {
  QbittorrentConfig(url: String, username: String, password: String)
}

pub type WatchConfig {
  WatchConfig(paths: List(String))
}

pub type SyncConfig {
  SyncConfig(recheck_delay_seconds: Int, min_file_size_mb: Int)
}

pub type ArrConfig {
  ArrConfig(url: String, api_key: String)
}

pub type Config {
  Config(
    qbittorrent: QbittorrentConfig,
    watch: WatchConfig,
    sync: SyncConfig,
    sonarr: Option(ArrConfig),
    radarr: Option(ArrConfig),
  )
}

pub type ConfigError {
  CannotReadFile(path: String, reason: simplifile.FileError)
  InvalidToml(tom.ParseError)
  InvalidField(tom.GetError)
}

pub fn load(path: String) -> Result(Config, ConfigError) {
  use contents <- result.try(
    simplifile.read(path) |> result.map_error(CannotReadFile(path, _)),
  )
  use document <- result.try(
    tom.parse(contents) |> result.map_error(InvalidToml),
  )
  parse_config(document)
}

fn parse_config(document: Dict(String, Toml)) -> Result(Config, ConfigError) {
  use qbittorrent <- result.try(parse_qbittorrent(document))
  use watch <- result.try(parse_watch(document))
  use sync <- result.try(parse_sync(document))
  use sonarr <- result.try(parse_optional_arr(document, "sonarr"))
  use radarr <- result.try(parse_optional_arr(document, "radarr"))
  Ok(Config(qbittorrent:, watch:, sync:, sonarr:, radarr:))
}

fn parse_qbittorrent(
  document: Dict(String, Toml),
) -> Result(QbittorrentConfig, ConfigError) {
  use url <- result.try(get_string(document, ["qbittorrent", "url"]))
  use username <- result.try(get_string(document, ["qbittorrent", "username"]))
  use password <- result.try(qbittorrent_password(document))
  Ok(QbittorrentConfig(url:, username:, password:))
}

/// QBITTORRENT_PASSWORD wins over the config file, so the secret can stay
/// out of arr-sync.toml entirely (Docker/compose secrets) — with the env
/// var set, the `password` field becomes optional.
fn qbittorrent_password(
  document: Dict(String, Toml),
) -> Result(String, ConfigError) {
  case os_env("QBITTORRENT_PASSWORD") {
    Ok(password) -> Ok(password)
    Error(Nil) -> get_string(document, ["qbittorrent", "password"])
  }
}

@external(erlang, "arr_sync_config_ffi", "os_env")
fn os_env(name: String) -> Result(String, Nil)

fn parse_watch(
  document: Dict(String, Toml),
) -> Result(WatchConfig, ConfigError) {
  use raw_paths <- result.try(
    tom.get_array(document, ["watch", "paths"])
    |> result.map_error(InvalidField),
  )
  use paths <- result.try(
    raw_paths |> list.try_map(tom.as_string) |> result.map_error(InvalidField),
  )
  Ok(WatchConfig(paths:))
}

fn parse_sync(document: Dict(String, Toml)) -> Result(SyncConfig, ConfigError) {
  use recheck_delay_seconds <- result.try(
    get_int(document, ["sync", "recheck_delay"]),
  )
  use min_file_size_mb <- result.try(
    get_int(document, ["sync", "min_file_size_mb"]),
  )
  Ok(SyncConfig(recheck_delay_seconds:, min_file_size_mb:))
}

// A missing [sonarr]/[radarr] section is fine (optional integrations);
// a malformed one is a real error.
fn parse_optional_arr(
  document: Dict(String, Toml),
  section: String,
) -> Result(Option(ArrConfig), ConfigError) {
  case tom.get_string(document, [section, "url"]) {
    Error(tom.NotFound(_)) -> Ok(None)
    Error(err) -> Error(InvalidField(err))
    Ok(url) -> {
      use api_key <- result.try(get_string(document, [section, "api_key"]))
      Ok(Some(ArrConfig(url:, api_key:)))
    }
  }
}

fn get_string(
  document: Dict(String, Toml),
  path: List(String),
) -> Result(String, ConfigError) {
  tom.get_string(document, path) |> result.map_error(InvalidField)
}

fn get_int(
  document: Dict(String, Toml),
  path: List(String),
) -> Result(Int, ConfigError) {
  tom.get_int(document, path) |> result.map_error(InvalidField)
}
