/**
 * The DeepSeek Harness desktop app exports its own profile and web origin to
 * child processes. Unit tests must not treat those ambient values as evidence
 * about the instance they construct, otherwise the same suite reports
 * `desktop` on a developer machine and `unknown` in CI.
 *
 * Node runs each test file in its own process, so clearing these keys at module
 * load is scoped to this file.
 */
const HARNESS_ENV_KEYS = [
  'DSH_PROFILE',
  'DSH_PROFILE_DIR',
  'DSH_HOME',
  'DSH_WEB_URL',
  'DSH_PET_PROFILE',
  'DSH_PET_HARNESS_KIND',
  'DSH_PET_HARNESS_TYPE',
  'DSH_PET_WEB_URL',
  'DSH_PET_TARGET_ID',
  'DSH_PET_INSTANCE_DIRECTORY',
]

export function clearAmbientHarnessEnv() {
  for (const key of HARNESS_ENV_KEYS) delete process.env[key]
}
