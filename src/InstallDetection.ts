import { execFile } from 'node:child_process'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)

/** Detect the App on the Harness host without opening it or exposing paths. */
export async function detectHostApp(): Promise<'installed' | 'not-found' | 'unknown'> {
  if (process.platform !== 'darwin') return 'unknown'
  try {
    const { stdout } = await execFileAsync('/usr/bin/osascript', ['-l', 'JavaScript', '-e', `
      ObjC.import('AppKit')
      const bundleId = 'com.sundusk.dsh-pet'
      const home = ObjC.unwrap($.NSHomeDirectory())
      const registered = $.NSWorkspace.sharedWorkspace.URLForApplicationWithBundleIdentifier(bundleId)
      const paths = ['/Applications/DSH Pet.app', home + '/Applications/DSH Pet.app']
      if (!registered.isNil()) paths.push(ObjC.unwrap(registered.path))
      const found = paths.some(path => {
        const bundle = $.NSBundle.bundleWithPath(path)
        return !bundle.isNil() && ObjC.unwrap(bundle.bundleIdentifier) === bundleId
      })
      found ? 'installed' : 'not-found'
    `], { timeout: 3_000, maxBuffer: 1_024 })
    const status = stdout.trim()
    return status === 'installed' || status === 'not-found' ? status : 'unknown'
  } catch {
    return 'unknown'
  }
}
