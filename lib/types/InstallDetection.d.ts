/** Detect the App on the Harness host without opening it or exposing paths. */
export declare function detectHostApp(): Promise<'installed' | 'not-found' | 'unknown'>;
