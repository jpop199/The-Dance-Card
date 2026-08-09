-- Run this only if Table Editor -> profiles has NO row for your account.
-- Get your user id from Authentication -> Users (click your user, copy the UID).

insert into profiles (id, email, role)
values ('PASTE-YOUR-USER-UID-HERE', 'your@email.com', 'developer')
on conflict (id) do update set role = 'developer';
