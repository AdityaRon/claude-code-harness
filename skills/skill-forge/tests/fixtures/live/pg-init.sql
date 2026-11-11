-- Seed for the live fixture. Tenant names are placeholders shaped like the
-- identifiers a mask pattern catches.
CREATE TABLE orders (
  id bigserial PRIMARY KEY,
  tenant text NOT NULL,
  amount numeric(10, 2) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO orders (tenant, amount)
SELECT 'cust-' || (ARRAY['alpha', 'beta', 'gamma'])[1 + (g % 3)], (g % 50) + 0.99
FROM generate_series(1, 30) AS g;

-- The read-only role a sql-readonly skill should connect as. No password: it
-- logs in through the container's local socket, the service's own identity.
CREATE ROLE reader LOGIN;
ALTER ROLE reader SET default_transaction_read_only = on;
GRANT USAGE ON SCHEMA public TO reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO reader;
