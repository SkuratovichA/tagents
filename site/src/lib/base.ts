/** The URL of a file from public/, under the base path the site is built for. */
export function asset(name: string): string {
  return `${import.meta.env.BASE_URL}${name}`
}
