EMACS ?= emacs

# A space-separated list of required package names
DEPS = seq inheritenv

INIT_PACKAGES := "(progn \
  (require 'package) \
  (push '(\"melpa\" . \"https://melpa.org/packages/\") package-archives) \
  (package-initialize) \
  (dolist (pkg '(PACKAGES)) \
    (unless (package-installed-p pkg) \
      (unless (assoc pkg package-archive-contents) \
        (package-refresh-contents)) \
      (package-install pkg))) \
  )"

# If OFFLINE is set (e.g. make OFFLINE=1), skip package init
ifndef OFFLINE
INIT_EVAL = --eval $(subst PACKAGES,${DEPS},${INIT_PACKAGES})
else
INIT_EVAL =
endif

all: build check package-lint clean

check: check-sync check-async
check-sync: SYNC_MODE = --eval "(setq ben-async-processing nil)"
check-%:
	${EMACS} -Q ${INIT_EVAL} ${SYNC_MODE} -batch -l ben.el -l ben-tests.el -f ert-run-tests-batch-and-exit

package-lint:
	${EMACS} -Q --eval $(subst PACKAGES,package-lint,${INIT_PACKAGES}) -batch -f package-lint-batch-and-exit ben.el

build: clean
	${EMACS} -Q ${INIT_EVAL} -L . -batch -f batch-byte-compile *.el

clean:
	rm -f *.elc

.PHONY:	all build check package-lint clean
