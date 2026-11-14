#!/bin/bash 

##########################################################################################
# Sanity-check the Tigress distribution.
##########################################################################################

TIGRESS=$1
TIGRESS_POST=$2
TIGRESS_HOME=$3

TIGRESS_TESTS=$TIGRESS_HOME/tests

echo "===================================================================================="
echo "This is the Tigress installation checker. It performs some rudimentary checks to"
echo "ensure that tigress and tigress_post are installed properly. Call it like this:"
echo "    > check-installation.sh PATH-TO-tigress PATH-TO-tigress_post PATH-TO-TIGRESS-HOME"
echo "For example, on a Darwin install you would say:"
echo "    > cd /Applications/tigress/4.1.0/tests"
echo "    > check-installation.sh ../tigress ../tigress_post /Applications/tigress/4.1.0"
echo ""
if ! [ -x "$(command -v jq)" ]; then
    echo "To fully run the Tigress installation check, please install 'jq'."
fi    
echo "===================================================================================="
echo ""

TMPDIR=/tmp/tigress-check
mkdir -p $TMPDIR

/bin/cp $TIGRESS_HOME/tigress.h $TMPDIR
/bin/cp $TIGRESS_TESTS/*.c $TMPDIR

cd $TMPDIR

UNAME_S=$(uname -s)
UNAME_M=$(uname -m)

echo "These are the check-installation configuration parameters:"
echo "   UNAME_M=$UNAME_M"
echo "   UNAME_S=$UNAME_S"
echo "   TMPDIR=$TMPDIR"
echo "   TIGRESS=$TIGRESS"
echo "   TIGRESS_POST=$TIGRESS_POST"
echo "   TIGRESS_HOME=$TIGRESS_HOME"
echo "   TIGRESS_TESTS=$TIGRESS_TESTS"
echo "   PWD=$PWD"

echo "===================================================================================="
echo ""

################################################################################################
# Utilities
################################################################################################
function COMPILE {
   echo ""
   echo "--------------------------------------------------------------------"
   echo "- Compiling the obfuscated file result.c: "
   echo "--------------------------------------------------------------------"
   gcc -o result.exe result.c; 
}

function EXECUTE {
   echo ""
   echo "--------------------------------------------------------------------"
   echo "- Executing the obfuscated program result.exe: "
   echo "--------------------------------------------------------------------"
   ./result.exe
}

function RUN_TIGRESS_CMD {
   echo ""
   echo "--------------------------------------------------------------------"
   echo "- Executing the Tigress command:"
   echo "--------------------------------------------------------------------"
   echo $1
   $1
}

################################################################################################
# Measuring effect, i.e, has anything changed? Requires 'jq' to be installed.
################################################################################################
EFFECT_BEFORE="--Transform=SoftwareMetrics --Functions=fib --SoftwareMetricsKind=halstead --SoftwareMetricsJsonFileName=before.json"
EFFECT_AFTER="--Transform=SoftwareMetrics  --Functions=fib --SoftwareMetricsKind=halstead --SoftwareMetricsJsonFileName=after.json"

function EFFECT_SHOW {
   echo ""
   echo "--------------------------------------------------------------------"
   echo "- Showing the syntactic effects of obfuscation:"
   echo "--------------------------------------------------------------------"
   if [ -x "$(command -v jq)" ]; then
      echo "HALSTEAD COMPLEXITY METRIC BEFORE TRANSFORMATION=`jq '.[0].length' before.json`"
      echo "HALSTEAD COMPLEXITY METRIC AFTER TRANSFORMATION=`jq '.[0].length' after.json`"
   else
      echo "HALSTEAD COMPLEXITY METRIC BEFORE TRANSFORMATION=`grep length before.json`"
      echo "HALSTEAD COMPLEXITY METRIC AFTER TRANSFORMATION=`grep length after.json`"
   fi
   echo ""
}

##########################################################################################
# Run a simple flatten test.
##########################################################################################

function FLATTEN {
   echo "===================================================================================="
   echo "= Running a Flatten transformation"
   echo "===================================================================================="
   /bin/rm -f result.c result.exe
   CMD="$TIGRESS \
             $EFFECT_BEFORE \
             --Transform=Flatten --Functions=fib,fac \
             $EFFECT_AFTER \
             test1.c --out=result.c"

   RUN_TIGRESS_CMD "$CMD"

   COMPILE

   EXECUTE

   EFFECT_SHOW
}

##########################################################################################
# Run a simple virtualization test.
##########################################################################################

function VIRTUALIZE {
   echo "===================================================================================="
   echo "= Running a Virtualize transformation"
   echo "===================================================================================="
   /bin/rm -f result.c result.exe

   CMD="$TIGRESS \
        $EFFECT_BEFORE \
        --Transform=Virtualize --Functions=fib,fac \
        $EFFECT_AFTER \
        test1.c --out=result.c"

   RUN_TIGRESS_CMD "$CMD"

   COMPILE

   EXECUTE

   EFFECT_SHOW
}

##########################################################################################
# Run a simple jit test, to make sure all the MyJit files are in place.
##########################################################################################

function JIT {
   echo "===================================================================================="
   echo "= Running a Jit transformation"
   echo "===================================================================================="
   /bin/rm -f result.c result.exe

   CMD="$TIGRESS \
         $EFFECT_BEFORE \
         --Transform=Jit --Functions=fib,fac \
         $EFFECT_AFTER \
         test1.c --out=result.c"

   RUN_TIGRESS_CMD "$CMD"

   COMPILE

   EXECUTE

   EFFECT_SHOW
}

##########################################################################################
# Run a simple checksum test. This is to make sure that tigress_post works.
##########################################################################################

function CHECKSUM {
   echo "===================================================================================="
   echo "= Running a Checksum transformation to make sure that tigress_post works"
   echo "===================================================================================="
   /bin/rm -f result.c result.exe

   if [ "$UNAME_S" = "Linux" ]; then
      INTEGRITY_OPTIONS="-static -fPIC -fno-plt -g"
      GCC_VERSION=$(gcc -dumpversion | sed 's/\..*//g')
      EXP_VERSION=9
      if [ $GCC_VERSION -eq $EXP_VERSION ]; then
         INTEGRITY_OPTIONS="$INTEGRITY_OPTIONS -fcf-protection=none"
      fi
      PTHREAD_OPTIONS="-pthread"
   else
      INTEGRITY_OPTIONS="-fPIC -fno-plt -g"
      PTHREAD_OPTIONS=""
   fi
   ALIGN_OPTIONS="-falign-functions=8"
   ALIGN_OPTIONS=""

   echo ""
   echo "--------------------------------------------------------------------"
   echo "- Executing the Tigress command:"
   echo "--------------------------------------------------------------------"
   $TIGRESS \
               --Transform=InitEntropy --Functions=main --InitEntropyKinds=vars \
               --Transform=InitOpaque  --Functions=main --InitOpaqueStructs=list,array,env \
               $EFFECT_BEFORE --Functions=main \
               --Transform=Checksum  \
                  --ChecksumRequiredNumberOfSegmentCheckers=0 \
                  --ChecksumAddressing=relative \
                  --ChecksumHashFunctionsFile=hashes.c \
                  --ChecksumResponseKinds=abort \
                  --ChecksumHashValueTypes=int32 \
                  --ChecksumFunctionsToBeCheckedAtCallSites=fib,fac \
                  --ChecksumCallCheckersToBeInsertedWhere="((fib beforeCall) (fac beforeCall))" \
               $EFFECT_AFTER --Functions=main\
               test1.c --out=result.c; \

   echo
   echo "--------------------------------------------------------------------"
   echo "- Compiling result.c and hashes.c:"
   echo "--------------------------------------------------------------------"
   CMD="gcc $INTEGRITY_OPTIONS $ALIGN_OPTIONS -o result.exe result.c -ldl $PTHREAD_OPTIONS"; echo $CMD; $CMD

   CMD="gcc -shared -o hashes.so -fPIC hashes.c"; echo $CMD; $CMD

   echo
   echo "--------------------------------------------------------------------"
   echo "- Applying tigress_post to result.exe:"
   echo "--------------------------------------------------------------------"
   CMD="$TIGRESS_POST \
      --Action=checksum \
      --HashFunctionsFile=$TMPDIR/hashes.so \
      --OverlapRate=0.5 \
       result.exe"; echo $CMD; $CMD

   echo "--------------------------------------------------------------------"
   echo "- Signing result.exe, if necessary:"
   echo "--------------------------------------------------------------------"
   if [ "$UNAME_S" = "Darwin" ]; then
      echo "codesign -s - result.exe"
      codesign -s - result.exe
   fi

   EXECUTE

   EFFECT_SHOW
}

##########################################################################################
# Try to merge 2 files. This is to check that tigress merge works.
##########################################################################################

function MERGE {
   echo "===================================================================================="
   echo "= Checking that tigress file merging works"
   echo "===================================================================================="
   /bin/rm -f result.exe result.c

   CMD="$TIGRESS --Merge merge1.c merge2.c --out=result.c"

   RUN_TIGRESS_CMD "$CMD"

   COMPILE

   EXECUTE

}

##########################################################################################
# Main
##########################################################################################

FLATTEN
VIRTUALIZE
JIT
CHECKSUM
MERGE

exit 0
