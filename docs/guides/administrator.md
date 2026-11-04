# Administrator guide

You manage who can do what, and how the lab's system behaves. You do not need to be technical, but you do need care: most things here affect everyone.

## First-run setup

A new deployment opens on a setup page. Enter the setup token you were given, create the first Admin account, and set the GST rate, credit days, working days, retention periods, and terms and conditions. You can change all of these later except the token, which is used once.

## Company details

**Admin → Company** shows the company's name, GSTIN, bank details, logo and accreditation details. These are read-only here. To change them, ask whoever runs your deployment to update the company's environment file and restart. Documents already issued keep the details they were issued with.

## Users

**Admin → Users → Add user.** Give a name, email, temporary password and one or more roles. Small labs can give one person several roles. Fill in **Designation** for signatories, since it prints on reports. For signatories, also upload a **signature image**.

Deactivate people who leave instead of removing them: their name must remain on past records. Deactivating ends their sessions immediately.

## Roles

Roles are lists of permissions, and you can edit them or add your own under **Admin → Roles**. Two safeguards apply: you cannot remove your own access to user management, and at least one role in use must keep it.

Be careful with these:

- **Customer access** lets someone see customer names. Technicians do not have it, on purpose.
- **Rates and invoices** expose prices.

## Settings

**Admin → Settings** holds tax rate, document number formats, report format details, reminder schedule, working days and retention.

Number formats use `{PREFIX}`, `{FY}` and `{SEQ:5}`. Changing a format affects only new documents.

The **Controls** group needs extra thought, and any change requires a reason that goes in the audit log:

| Control | Normally | Change it only if |
|---|---|---|
| Allow self-approval of results | No | The lab is too small to have someone else approve |
| Allow same reviewer and signatory | No | The lab is too small to have two people |
| Hide customer identity from technicians | Yes | Your accreditation body and quality manager agree |
| Block instruments past calibration due date | No | You want a hard stop instead of a warning |

**Terms** are versioned. Saving creates a new version; issued documents keep theirs. **Holidays** and working days drive due dates.

## Masters

**Masters** holds tests, parameters, methods, specifications, groups, formulas, instruments, departments, units, rates and lists such as deviation types.

- Records in use cannot be deleted. Deactivate them instead; past documents are unaffected, as they store their own copy.
- Excel import is all or nothing: if a row is wrong, nothing is saved and you get the row numbers to fix.
- **Formulas** have a test console. Saving a changed expression creates a new version, and each result records the version it used.
- Each test needs parameters before it can be planned.
- **Accreditation** is flagged on the method and on each parameter, with a validity date. A parameter counts as in scope only when both are valid.

## Audit log

**Admin → Audit log** records who did what and when, with before and after values, the IP address and any reason. Nobody can edit or delete it. Job, sample, test, report and invoice pages also have their own history.

## Demo data

If your deployment was set up with demo data, have it removed before going live.
