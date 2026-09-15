# Getting started: your first hour with PerfectCRM

Sign in at `https://perfectcrm.sherpaholidays.com` with
`info@sherpaholidays.com`. Today is the landing page; the phone tab bar at
the bottom (Today, Inbox, Leads, Clients, More) reaches everything
one-handed.

1. **Pick Paper or Night** in Settings → Appearance. It applies instantly.
2. **Connect the mailbox** in Settings → Mailbox: your Gmail address, an
   app password (Google Account → Security → App passwords, named
   PerfectCRM), then Test connection.
3. **Run the import preview** in Settings → Import history. Start with the
   last 90 days, review the rows, then commit.
4. **Review triage** in Inbox → Triage. Confirm each unknown sender as a
   client, lead, or organization, or ignore it.
5. **Answer what is waiting** on Today: the Replies waiting list first,
   then follow-ups. Tap the circle to mark one done.
6. **Set the voice guide** in Settings → AI drafts → Edit voice, so drafts
   sound like you. Nothing ever sends without Send.
7. **Write your name and signature** in Settings → Email replies.
8. **Check the PerfectBook connection** in Settings → PerfectBook → Test
   connection. Bookings and the trip catalog mirror from there.
9. **Walk the pipeline** and drag any stale card to its true stage. Lost
   asks for a reason.
10. **Send a test quote** to yourself from any client page → New quote, and
    open the accept link on your phone the way a client would.

Demo data (only on a local machine, never production):

```sh
DEMO_SEED=1 bin/rails db:seed   # load; safe to rerun
bin/rails runner 'require "./db/seeds/demo_seed"; DemoSeed.wipe!'  # wipe
```

The demo world is six clients, four open leads at different stages plus one
converted lead, two organizations, a dozen messages across seven threads,
three quotes (one accepted), six tasks, and mirrored Everest, Annapurna, and
Langtang trips with departures and bookings — so Today, the inbox, the
pipeline, and quotes all look alive.
