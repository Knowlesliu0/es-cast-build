# ES Cast build snapshot

This repository, if approved, contains the ES Cast iOS source and synthetic tests needed for an unsigned build. It is a source snapshot without the original private Git history, device logs, phone recordings, Apple credentials, signing profiles, or billing records.

Run the manually dispatched workflow with the standard `xcode-27` runner. Build results are unsigned and require valid Apple signing before installation. Standard public-repository runner minutes are free under GitHub rules; included artifact storage limits still apply.

This build does not establish a CarPlay entitlement, vehicle video compatibility, receiver stability, or audiovisual synchronization. Build 10 prepares a direct AirPlay baseline and a local diagnostic snapshot.
