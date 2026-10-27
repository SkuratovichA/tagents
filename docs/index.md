---
layout: home

hero:
  name: tagents
  text: Know which Claude Code session needs you
  tagline: A live dashboard of every Claude Code session running under tmux, from inside tmux. See what is blocked, jump straight to it, and never lose a chat.
  actions:
    - theme: brand
      text: Get started
      link: /guide/getting-started
    - theme: alt
      text: GitHub
      link: https://github.com/SkuratovichA/tagents

features:
  - title: See what is blocked
    details: A session waiting on a permission prompt or an answer is marked BLOCKED and counted in its project's header, so nothing waits unnoticed behind another window.
    link: /guide/states
    linkText: The states
  - title: A dashboard with the chat beside it
    details: The dashboard is a session of its own, with the list on the left and the chat you select on the right. Type into the chat without leaving.
    link: /guide/dashboard
    linkText: The dashboard
  - title: A banner when you are needed
    details: A question, a permission prompt or a finished turn posts a desktop notice, and clicking it docks that chat.
    link: /guide/notifications
    linkText: Notifications
  - title: Never lose a session
    details: Close the laptop, reboot, kill the tmux server. Your chats come back where they were, on the account and with the model they ran on.
    link: /guide/resurrect
    linkText: Resurrect
  - title: Several accounts
    details: Each agent starts on the Claude login its directory calls for, and every row says which login it is on.
    link: /guide/accounts
    linkText: Accounts
  - title: Know what it costs
    details: Each row carries its context size and spend, with the month against your limit in the footer.
    link: /guide/cost
    linkText: Cost
---

<div class="hero-demo">

![The tagents dashboard: chats grouped by project, one turns BLOCKED, enter opens it beside the list](./images/hero.gif)

</div>

<style>
.hero-demo {
  max-width: 1152px;
  margin: 48px auto 0;
  padding: 0 24px;
}
.hero-demo img {
  width: 100%;
  border-radius: 12px;
  box-shadow: 0 12px 40px rgba(0, 0, 0, 0.25);
}
</style>
