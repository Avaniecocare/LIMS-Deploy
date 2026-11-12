# Accounts guide

## Rates

**Masters → Standard rates** and **Customer rates** hold rates with effective dates. For new work the system uses the customer's rate if there is one, otherwise the standard rate. A job from a quotation keeps the quotation's rates.

## Invoicing

**Invoices → Ready to invoice** lists jobs with approved work not yet billed.

1. Select one job, or several for the same customer, and create a **draft**. Cancelled tests are left out.
2. Check it. You can add a discount, or change a rate on a line with a reason.
3. **Issue.** It gets its number, date and due date from the customer's credit days. Details are frozen, and the PDF always shows them as issued.

GST follows the place of supply: CGST and SGST inside your state, IGST otherwise.

An **issued invoice can't be edited.** Correct it by cancelling it, if nothing has been paid, or with a **credit note**, which needs an amount and a reason. Its GST is worked out the same way.

## Payments

**Record payment:** date, mode, reference and amount, then how much goes to each invoice. Anything unallocated stays on account as an **advance**, which you can **apply** later. The invoice moves to Partially Paid or Paid by itself. Entered one by mistake? **Reverse** it with a reason: the record stays and the invoices go back to their earlier balance.

## Due invoices

**Due Invoices** lists everything unpaid: balance, days overdue and ageing (Not Due, 0–30, 31–60, 61–90, 90+). Overdue is worked out from the due date. A payment due today is not yet overdue. Filter by ageing or customer, see totals per customer, and from here you can:

- record a payment
- send a **reminder**, which is logged
- produce a **statement of account** or an **Excel** file

Automatic reminders are off by default. An Admin can turn them on and set which days after the due date they go.

## Reports

The Invoice Register includes the GST summary. There is also a Payment Register, a Quotation Register, and the Outstanding and Ageing report.
