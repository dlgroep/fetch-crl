#
# @(#)$Id$
# Makefile for fetch-crl3
# David Groep, Nikhef <davidg@nikhef.nl>
#

NAME=$(shell echo *.spec | sed 's/\.spec//')
VERSION=$(shell egrep '^Version:' ${NAME}.spec | colrm 1 9)
RELEASE=${NAME}-${VERSION}
PATCHLEVEL=$(shell egrep '^Release:' ${NAME}.spec | colrm 1 9 | sed -e 's/%.*//' )
RPMTOPDIR=$(shell rpm --eval '%_topdir')
PREFIX=/usr
ETC=/etc
CACHE=/var/cache
FILES=fetch-crl fetch-crl.8 fetch-crl-cron.cron fetch-crl-cron.init fetch-crl-boot.init fetch-crl.cnf fetch-crl.cnf.example NOTICE LICENSE README CHANGES fetch-crl.spec Makefile
# source files that will constitute fetch-crl as a single file, with the primary perl script first
SOURCEFILES=fetch-crl3.pl CRL.pm CRLWriter.pm ConfigTiny.pm FCLog.pm OSSL.pm TrustAnchor.pm base64.pm

all:	configure

tar:    clean configure fetch-crl
	-rm -rf /var/tmp/${RELEASE} /var/tmp/${RELEASE}-buildroot
	-mkdir /var/tmp/${RELEASE}
	cp -r ${FILES} /var/tmp/${RELEASE}
	-chmod -R u+rw /var/tmp/${RELEASE}
	cd /var/tmp/ ; tar  cvfz ${RELEASE}.tar.gz --exclude=CVS \
                    --exclude='*~' --exclude='#*#' --exclude='20*' ${RELEASE}
	cp /var/tmp/${RELEASE}.tar.gz .

#####################################################################
# Create substitution script
####################################################################
#
# This target reads the config file and creates a shell script which
# can substitute variables of the form @VAR@ for all config
# variables VAR. 

config.sh: Makefile $(_test_dep) config.mk
	@cp /dev/null makefile.tmp
	@echo include config.mk >>makefile.tmp
	@echo dumpvars: >>makefile.tmp
	@cat config.mk | \
	 perl >>makefile.tmp -e 'my $$fmt = "\t\@echo \"-e \\\"s\@%s\@\$$(%s)g\\\" \\\\\"" ; while (<>) { $$v{$$1}=1 if /^([A-Za-z0-9_]+)\s*:?=.*$$/; } map { printf "$$fmt >>config.sh\n", $$_, $$_; } sort(keys(%v)); print "\n"; '
	@echo '#!/bin/sh' >config.sh
	@echo 'sed \' >>config.sh
	@$(MAKE) -f makefile.tmp dumpvars >/dev/null
	@echo ' -e "s/\@MSG\@/ ** Generated file : do not edit **/"'>>config.sh
	@chmod oug+x config.sh
	@rm makefile.tmp

####################################################################
# Configure
####################################################################

fetch-crl: $(SOURCEFILES)
	cat $(SOURCEFILES) > $@ && chmod +x $@

%:: %.cin config.sh
	@echo configuring $@ ...
	@rm -f $@ ; cp $< $@
	@./config.sh <$< >$@ ; chmod oug-w $@

%.$(MANSECT):: %.$(MANSECT).man.cin
	@echo creating $@ ...
	@./config.sh <$< >$@ ; chmod oug-w $@

configure: $(shell find . -name \*\.cin 2>/dev/null | sed -e 's/.cin//' || echo)

install: configure
	install -m755 -D fetch-crl           $(PREFIX)/sbin/fetch-crl
	install -m644 -D fetch-crl-cron.cron $(PREFIX)/share/doc/$(RELEASE)/fetch-crl-cron.cron
	install -m644 -D fetch-crl-cron.init $(PREFIX)/share/doc/$(RELEASE)/fetch-crl-cron.init
	install -m644 -D fetch-crl-boot.init $(PREFIX)/share/doc/$(RELEASE)/fetch-crl-boot.init
	install -m644 -D fetch-crl.8         $(PREFIX)/share/man/man8/fetch-crl.8
	install -m644 -D fetch-crl.cnf       $(ETC)/fetch-crl.conf
	install -m644 fetch-crl.cnf.example  $(PREFIX)/share/doc/$(RELEASE)/fetch-crl.conf.example
	install -m644 README                 $(PREFIX)/share/doc/$(RELEASE)/README
	install -m644 NOTICE                 $(PREFIX)/share/doc/$(RELEASE)/NOTICE
	install -m644 LICENSE                $(PREFIX)/share/doc/$(RELEASE)/LICENSE
	install -m644 CHANGES                $(PREFIX)/share/doc/$(RELEASE)/CHANGES
	mkdir -p $(CACHE)/fetch-crl && chmod 0700 $(CACHE)/fetch-crl

rpm: tar
	rpmbuild -ta ${RELEASE}.tar.gz
	@if [ -f ${RPMTOPDIR}/SRPMS/${NAME}-${VERSION}-${PATCHLEVEL}.src.rpm ] ; then \
	  mv ${RPMTOPDIR}/SRPMS/${NAME}*-${VERSION}-${PATCHLEVEL}.src.rpm . ;  \
	fi
	@if [ -f ${RPMTOPDIR}/RPMS/i386/${NAME}-${VERSION}-${PATCHLEVEL}.i386.rpm ] ; then \
	  mv ${RPMTOPDIR}/RPMS/i386/${NAME}*-${VERSION}-${PATCHLEVEL}.i386.rpm . ;  \
	fi
	@if [ -f ${RPMTOPDIR}/RPMS/i686/${NAME}-${VERSION}-${PATCHLEVEL}.i686.rpm ] ; then \
	  mv ${RPMTOPDIR}/RPMS/i686/${NAME}*-${VERSION}-${PATCHLEVEL}.i686.rpm . ;  \
	fi
	@if [ -f ${RPMTOPDIR}/RPMS/noarch/${NAME}-${VERSION}-${PATCHLEVEL}.noarch.rpm ] ; then \
	  mv ${RPMTOPDIR}/RPMS/noarch/${NAME}*-${VERSION}-${PATCHLEVEL}.noarch.rpm . ;  \
	fi
	@echo DO NOT FORGET TO SIGN THE RPM WITH rpm --resign ${NAME}*-${VERSION}-${PATCHLEVEL}.noarch.rpm

clean:
	-rm -rf *.tar.gz *.rpm fetch-crl config.sh fetch-crl.spec 
