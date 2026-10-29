import { createFileRoute } from '@tanstack/react-router'
import { NotFoundPage } from '../components/NotFoundPage'
import { notFoundHead } from '../lib/head'

// Every address no other route has lands here, and /404 is one of them. It is prerendered as 404.html, which the host serves for any address nothing answers, so the browser hydrates that file at the address the visitor typed: both must be the same route, or the hydration fails.
export const Route = createFileRoute('/$')({
  head: () => notFoundHead(),
  component: NotFoundPage,
})
