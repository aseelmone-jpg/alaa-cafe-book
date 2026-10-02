-- Add explicit source/destination validation for new fund-transfer vouchers.
-- Existing vouchers without transferRole are accepted unchanged.
begin;
create or replace function public.journal_lines_are_balanced(p_lines jsonb)
returns boolean
language plpgsql
immutable
strict
set search_path = ''
as $function$
declare
  v_line jsonb;
  v_side text;
  v_account text;
  v_amount_text text;
  v_amount numeric;
  v_debit numeric := 0;
  v_credit numeric := 0;
  v_count integer := 0;
  v_role text;
  v_has_role boolean := false;
  v_has_no_role boolean := false;
  v_first_account text;
  v_multiple_accounts boolean := false;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    return false;
  end if;
  for v_line in select value from jsonb_array_elements(p_lines) loop
    v_count := v_count + 1;
    v_side := v_line ->> 'side';
    v_account := btrim(coalesce(v_line ->> 'particulars', ''));
    v_amount_text := v_line ->> 'amount';
    v_role := v_line ->> 'transferRole';
    if v_side is null or v_side not in ('debit', 'credit') or v_account = '' then
      return false;
    end if;
    if v_first_account is null then v_first_account := v_account;
    elsif v_first_account <> v_account then v_multiple_accounts := true;
    end if;
    if v_role is null then
      v_has_no_role := true;
    else
      v_has_role := true;
      if v_account not in ('Cash', 'UPI Account', 'Bank')
         or v_role <> (case when v_side = 'credit' then 'source' else 'destination' end) then
        return false;
      end if;
    end if;
    if v_amount_text is null or v_amount_text !~ '^(0|[1-9][0-9]{0,9})(\.[0-9]{1,2})?$' then
      return false;
    end if;
    v_amount := v_amount_text::numeric;
    if v_amount <= 0 then
      return false;
    end if;
    if v_side = 'debit' then v_debit := v_debit + v_amount;
    else v_credit := v_credit + v_amount;
    end if;
  end loop;
  return v_count >= 2 and v_debit > 0 and v_debit = v_credit
    and not (v_has_role and (v_has_no_role or not v_multiple_accounts));
exception when others then
  return false;
end;
$function$;

revoke all on function public.journal_lines_are_balanced(jsonb) from public, anon;
grant execute on function public.journal_lines_are_balanced(jsonb) to authenticated;

do $check$
begin
  if exists (select 1 from public.journal_vouchers where not public.journal_lines_are_balanced(lines)) then
    raise exception 'A saved voucher conflicts with the transfer-role validation; migration rolled back';
  end if;
end;
$check$;
commit;
