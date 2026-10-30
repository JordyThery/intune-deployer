# Changelog

## Unreleased
Fixes for what JTKit ROADMAP step 11 (the release check) found in Intune Deployer, 2026-10-30, in the order Jordy chose.
- Every request to a tenant is sent only with a sign-in token of that tenant profile's tenant; otherwise nothing is sent and Apply says which tenant it was. A profile with a verified domain is checked against that tenant's verified domains before its first write. A saved sign-in is no longer tied to a tenant just because it is the only account on the Mac. (bug 5)
- Apply refuses a plan made for another tenant profile or tenant ID, and does nothing while another Plan or Apply runs; Remove Baseline too. (bug 7)
- Orphans and Remove Baseline cover only the tenant profile's own objects. New and updated objects carry the profile's tag (`[IntuneDeployerProfile:…]`) next to the identity tag; objects deployed before count as the profile's when their name carries its naming prefix. The first Plan after updating shows each existing object as an update once (its description gains the profile tag). (bug 2)
- Assignments are compared with the tenant's: Apply sends only those that differ, and an unchanged baseline shows "Everything is already up to date". (bug 1)
- Groups and built-in template filters the app creates carry the profile's tag; Remove Baseline deletes those filters, and a group only when it carries the profile's tag and has no members. Every other group the profile's assignments name (untagged, another profile's, or with members) is listed and kept. (bug 3)
- Baseline Settings warns when another tenant profile uses the same naming prefix: objects deployed before profile tags are matched by it.
- An app whose package upload failed after it was created is uploaded again by the next Apply. (bug 4)
- Several groups with the same name are a plan error instead of the first one being used. (bug 6)
- A tenant filter that names no platform is a plan error instead of being assigned unchecked. (bug 10)
- The release check's live check now requires that a second Apply of an unchanged baseline sends nothing.
