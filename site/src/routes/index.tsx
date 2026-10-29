import { createFileRoute } from '@tanstack/react-router'
import { Home } from '../components/Home'
import { DESCRIPTION, TITLE } from '../content'
import { pageHead } from '../lib/head'

export const Route = createFileRoute('/')({
  head: () => pageHead(TITLE, DESCRIPTION),
  component: Home,
})
