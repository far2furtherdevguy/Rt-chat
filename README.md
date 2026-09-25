# RT Chat

A WhatsApp-style chat app for Android, built with Flutter. The app is called **RT Chat** everywhere it is shown (internal project name: *Real time chat*, package `rt_chat`).

- **Chat backend:** Supabase (database, realtime, presence, file storage)
- **Sign-in:** Firebase Authentication with Google. Your Firebase user ID is your account ID, and you pick a unique `@username`
- **Local storage:** SQLite on the phone, so chats open instantly and work offline. Messages you send offline go out automatically when you reconnect
- **Build:** GitHub Actions builds the APK for you. You never need Android Studio

> Ignore anything about OpenRouter. This app does not use it.

---

## What is in the app

| Area | Features |
|---|---|
| Chats | 1-to-1 chats, groups, channels (owner posts, others follow) |
| Messages | Multi-line input, swipe to reply, copy text, links highlighted and tappable, pin message, edit (15 min), delete for me, delete for everyone (48 h), timestamps, status ticks (sending / sent / delivered / read) |
| Media | Photos, video, audio, any file. Built-in video and audio player, full-screen image viewer with zoom |
| Fun | Emoji picker, stickers, GIF search (GIPHY) |
| People | Profile picture, name, about, online / last seen |
| Notifications | New-message notifications with an inline **Reply** box |
| Privacy | End-to-end encryption for text in 1-to-1 chats and groups (details below) |
| Look | Light / dark / auto, accent colour, chat theme |
| Data | Low data mode, upload size limit, cached images |
| Speed | Lightweight animations, no shader ripples, paged message lists, downsized image decoding for low-end phones |
| Dev | Hidden debug log, locked with a password |

### Hidden debug log
Settings, scroll to the bottom, tap the version text 7 times, enter the password `pass`. Users never see this. The password is the `debugPassword` constant near the top of `lib/main.dart`.

---

## Setup (about 20 minutes)

You need: a GitHub account, a Google account, a free Supabase project, a free Firebase project.

### 1. Create the GitHub repository
Create a new repo and upload these files keeping the folder layout:

```
lib/main.dart
pubspec.yaml
.gitignore
README.md
.github/workflows/build.yml
```

The Android project is generated automatically during the build, so you do not upload an `android/` folder.

### 2. Supabase

1. Create a project at supabase.com.
2. Open **SQL Editor**, paste the whole script below, and run it.
3. Open **Project Settings > API** and copy the **Project URL** and the **anon public key**.

```sql
-- ───────── tables ─────────
create table profiles (
  uid text primary key,
  username text not null,
  name text not null default '',
  photo text,
  about text,
  pubkey text,
  last_seen timestamptz default now(),
  created_at timestamptz default now()
);
create unique index profiles_username_lower on profiles (lower(username));

create table chats (
  id text primary key,
  kind text not null check (kind in ('direct','group','channel')),
  name text not null default '',
  photo text,
  owner text,
  created_at timestamptz default now()
);

create table chat_members (
  chat_id text not null references chats(id) on delete cascade,
  uid text not null,
  role text not null default 'member',
  joined_at timestamptz default now(),
  primary key (chat_id, uid)
);
create index chat_members_uid on chat_members (uid);

create table group_keys (
  chat_id text not null references chats(id) on delete cascade,
  uid text not null,
  from_uid text not null,
  wrapped text not null,
  primary key (chat_id, uid)
);

create table messages (
  id text primary key,
  chat_id text not null references chats(id) on delete cascade,
  sender text not null,
  kind text not null default 'text',
  body text not null default '',
  enc boolean not null default false,
  media_url text,
  media_name text,
  media_size bigint default 0,
  reply_to text,
  ts bigint not null,
  edited boolean not null default false,
  deleted boolean not null default false,
  pinned boolean not null default false,
  updated_at timestamptz not null default now()
);
create index messages_chat_upd on messages (chat_id, updated_at);
create index messages_upd on messages (updated_at);

create table receipts (
  message_id text not null,
  uid text not null,
  chat_id text not null,
  st int not null,
  updated_at timestamptz not null default now(),
  primary key (message_id, uid)
);
create index receipts_upd on receipts (updated_at);

-- ───────── keep updated_at fresh (used for syncing) ─────────
create function touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
create trigger t_messages before insert or update on messages
  for each row execute function touch_updated_at();
create trigger t_receipts before insert or update on receipts
  for each row execute function touch_updated_at();

-- ───────── access rules (see "Security note" below) ─────────
alter table profiles enable row level security;
alter table chats enable row level security;
alter table chat_members enable row level security;
alter table group_keys enable row level security;
alter table messages enable row level security;
alter table receipts enable row level security;
create policy "open" on profiles for all using (true) with check (true);
create policy "open" on chats for all using (true) with check (true);
create policy "open" on chat_members for all using (true) with check (true);
create policy "open" on group_keys for all using (true) with check (true);
create policy "open" on messages for all using (true) with check (true);
create policy "open" on receipts for all using (true) with check (true);

-- ───────── realtime ─────────
alter publication supabase_realtime add table messages, receipts, chat_members;

-- ───────── file storage (25 MB limit per file) ─────────
insert into storage.buckets (id, name, public, file_size_limit)
values ('media', 'media', true, 26214400)
on conflict (id) do update set public = true, file_size_limit = 26214400;
create policy "media open" on storage.objects for all
  using (bucket_id = 'media') with check (bucket_id = 'media');
```

### 3. Firebase (Google sign-in)

1. Go to console.firebase.google.com and create a project.
2. **Build > Authentication > Get started > Sign-in method > Google > Enable.** Save.
3. On the same Google provider page, open **Web SDK configuration** and copy the **Web client ID**. This becomes `GOOGLE_WEB_CLIENT_ID`.
4. **Project settings (gear icon) > General > Your apps > Add app > Android.**
   - Android package name: `com.rtchat.rt_chat`
   - Skip the SHA-1 for now (you get it in step 5). Register the app.
5. After the first build (step 6), come back to **Project settings > Your apps > your Android app > Add fingerprint** and paste the SHA-1 shown in the build summary.
6. From the same page, copy these values. If you download `google-services.json` you can read them from it:

| Secret name | Where to find it |
|---|---|
| `FIREBASE_API_KEY` | `client[0].api_key[0].current_key` in google-services.json, or "Web API Key" in Project settings |
| `FIREBASE_APP_ID` | `client[0].client_info.mobilesdk_app_id` (looks like `1:1234:android:abcd`) |
| `FIREBASE_PROJECT_ID` | Project ID |
| `FIREBASE_SENDER_ID` | Project number / Sender ID |
| `GOOGLE_WEB_CLIENT_ID` | Step 3 |

You do **not** need to add google-services.json to the repo. The app is configured through the secrets below.

### 4. Optional: GIF search
Create a free key at developers.giphy.com and save it as the secret `GIPHY_API_KEY`. Without it the GIF tab shows a note and everything else works.

### 5. Add GitHub secrets
Repo > **Settings > Secrets and variables > Actions > New repository secret**. Add:

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `FIREBASE_API_KEY`, `FIREBASE_APP_ID`, `FIREBASE_PROJECT_ID`, `FIREBASE_SENDER_ID`, `GOOGLE_WEB_CLIENT_ID`, and optionally `GIPHY_API_KEY`.

Optional variable (Variables tab): `MAX_UPLOAD_MB` (default 25). If you raise it, also raise the bucket limit in Supabase (Storage > media > settings). The free plan allows up to 50 MB.

### 6. Build
Repo > **Actions > Build RT Chat APK > Run workflow**. Pushing to `main` also builds. When it finishes:

1. Open the run and read the **summary**. It shows the signing **SHA-1**. Add it to Firebase (step 3.5). Google sign-in will not work until you do.
2. Download the **RT-Chat-apk** artifact, unzip it, install `RT-Chat.apk` on your phone.

The workflow keeps the same signing key between runs, so the SHA-1 stays the same. GitHub deletes caches that are unused for 7 days. If a rebuild shows a different SHA-1, add the new one in Firebase too (you can have several).

### 7. First launch
Sign in with Google, choose a `@username`, and you are in. Install on a second phone, sign in with another account, search the username, and start chatting.

---

## How it works (short)

- **Sync:** the app keeps a cursor per table (`updated_at`). On start and when reopened it pulls anything newer, then Supabase Realtime pushes live changes. Everything is written to SQLite first, then shown.
- **Offline sending:** a message is saved as *pending* (clock icon) and retried every 15 seconds and on reconnect. Media uploads happen at send time and are retried too.
- **Ticks:** clock = sending, one tick = sent, two grey = delivered, two blue = read. In groups, blue means everyone has read it. Channels show no ticks.
- **Online status:** Supabase Presence. Last seen is saved when the app goes to the background. Low data mode turns presence off.
- **Encryption:**
  - 1-to-1 chats: X25519 key agreement, HKDF-SHA256, AES-256-GCM. The private key never leaves the phone (Android Keystore backed secure storage).
  - Groups: a random group key is created by the creator and wrapped separately for each member with their pairwise key.
  - Channels are public and are **not** end-to-end encrypted, the same as WhatsApp channels.
  - Photos, video, audio and files are stored in a public Supabase bucket under unguessable file names. Only text is end-to-end encrypted.
  - If you uninstall the app, the private key is lost and old encrypted messages cannot be decrypted on the new install. This is the trade-off of having no server-side key backup.
- **Notification reply:** the reply box in the notification sends the message through the running app.

## Limits you should know about

1. **Notifications need the app process alive.** There is no push server (FCM) in this build, so notifications appear while the app is open or recently backgrounded. If Android has killed the app, messages arrive when you open it. Real push needs a small Supabase Edge Function that calls FCM. That is the natural next step.
2. **Security note.** Sign-in is handled by Firebase, but Supabase sees only the public anon key, so the database rules above are open. Anyone who extracts the anon key from the APK could read or write rows. Text in chats is end-to-end encrypted so it stays unreadable, but names, message timing and file links are not protected, and someone could impersonate a user. Before a public launch, switch Supabase to *Third-party auth with Firebase* and replace the `open` policies with rules based on `auth.jwt()->>'sub'`.
3. **Live updates listen to all message changes** and the app filters them on the phone. This is fine for small groups of users. For a big user base add server-side filters.
4. **No voice recorder, voice or video calls, or adding members to an existing group yet.** Audio files can be sent and played.
5. **Stickers are large emoji.** Custom sticker packs need image assets.
6. Video thumbnails are not generated, to keep the app light on low-end phones.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Setup needed" screen | A GitHub secret is missing or misspelled. Fix it and re-run the workflow. |
| Google sign-in error, code 10 / DEVELOPER_ERROR | The SHA-1 from the build summary is not in Firebase, or the package name is not exactly `com.rtchat.rt_chat`. |
| Sign-in works but chats fail with a database error | The SQL script did not finish. Run it again on a fresh project, or look for the first error message. |
| "Waiting for encryption key" | The other person has not opened the app since installing. Their key appears after their first launch. |
| Images are not showing | Check the `media` bucket exists and is public. Low data mode makes you tap photos to load them. |
| Build fails while downloading dependencies | Re-run the workflow. It retries 3 times and caches downloads to avoid Maven rate limits. |
| Build fails after a new Flutter release | Open the failed step, copy the first error, and share it. Pinning `flutter-version` in `build.yml` also works. |

## Files

- `lib/main.dart` – the whole app
- `pubspec.yaml` – dependencies
- `.github/workflows/build.yml` – APK build (also generates and patches the Android project)
- `.gitignore`
