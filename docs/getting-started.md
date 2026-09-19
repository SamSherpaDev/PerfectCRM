# Getting started: your first hour with PerfectCRM

Sign in at `https://perfectcrm.sherpaholidays.com` with
`info@sherpaholidays.com`. Today is the landing page; the phone tab bar at
the bottom (Today, Inbox, Leads, Clients, More) reaches everything
one-handed.

1. **Pick Paper or Night** in Settings → Appearance. It applies instantly.
2. **Connect the mailbox** using the [Mail setup guide](../README.md#mail):
   Settings → Mailbox → Connect mailbox (Microsoft 365) → Test connection.
   A first connect starts from now; past mail stays for Import history.
3. **Run the import preview** in Settings → Import history. Start with the
   last 90 days, review the rows, then commit.
4. **Review triage** in Inbox → Triage. Confirm each unknown sender as a
   client, lead, or organization, or ignore it.
5. **Answer what is waiting** on Today: the Replies waiting list first,
   then follow-ups. Tap the circle to mark one done.
6. **Configure AI assistance** using the [AI setup guide](../README.md#ai-assistance),
   including the provider key and Voice guide in Settings → AI assistance.
7. **Write your name, upload your logo, and set your signature** in Settings → Signature.
8. **Check the PerfectBook connection** in Settings → PerfectBook → Test
   connection. Bookings and the trip catalog mirror from there.
9. **Walk the pipeline** and drag any stale card to its true stage. Lost
   asks for a reason.
10. **Send a test quote** to yourself from any client page → New quote, and
    open the accept link on your phone the way a client would.

## Demo data

Only on a local machine, never production:

```sh
DEMO_SEED=1 bin/rails db:seed   # load; safe to rerun
bin/rails runner 'require "./db/seeds/demo_seed"; DemoSeed.wipe!'  # wipe
```

The demo includes travelers, leads, conversations, quotes, tasks, and
PerfectBook mirrors. The dataset is defined in
[`db/seeds/demo_seed.rb`](../db/seeds/demo_seed.rb).

Demo-created rows are recorded in a database manifest. Loading rejects
collisions with unmarked records. Wiping deletes only manifest rows and
refuses if unmarked records are attached; existing data from before the
manifest was introduced is never automatically claimed or deleted.
Demo loading leaves PerfectBook sync cursors untouched.
Reseeding preserves existing pipeline stages and leaves converted leads
read-only, using their existing clients for downstream records. Real
PerfectBook syncs release demo ownership of the mirrors they update;
subsequent wipes preserve them and reseeding rejects those collisions.
