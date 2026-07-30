Unseal Key 1: XUfjePMU6SAVHEP5iTt+EbdeUq4bPsliFZ13yQ1D6fx+
Unseal Key 2: CiuA5PxpmnCofjJfANYId6sc8oPcLe3l4kRZpYaTvxSt
Unseal Key 3: wpbmRieiOYwoq+w7LqriWHtYEbSjJoajyZagGNUdxCHt

Initial Root Token: s.Tcx0h5aYcDO11SiQkEjC5XMW

Vault initialized with 3 key shares and a key threshold of 2. Please securely
distribute the key shares printed above. When the Vault is re-sealed,
restarted, or stopped, you must supply at least 2 of these keys to unseal it
before it can start servicing requests.

Vault does not store the generated root key. Without at least 2 keys to
reconstruct the root key, Vault will remain permanently sealed!

It is possible to generate new unseal keys, provided you have a quorum
of existing unseal keys shares. See "bao operator rotate-keys" for more
information.nable to use a TTY - input is not a terminal or the right kind of file
Error initializing: Error making API request.

URL: PUT http://127.0.0.1:8200/v1/sys/init
Code: 400. Errors:

* Vault is already initialized
command terminated with exit code 2
