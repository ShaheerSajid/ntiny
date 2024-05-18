export LM_LICENSE_FILE=5280@10.3.212.20 
export CDS_LIC_FILE=$LM_LICENSE_FILE 

PVS=/home/shaheer/cadence/installs/PVS201/bin/pvs
SCRIPT=/home/shaheer/Documents/bare-metal-processor/flows/signoff/pvs
OUTPUT=$SCRIPT/output
RULE=/home/shaheer/Documents/bare-metal-processor/flows/65GP_TT/drc

#add SR
klayout \
-rd file1=../../physical_design/work/top.gds \
-rd file2=../../65GP_TT/gds/N65_Mu_SR_20191227_WLCSP_0401.gds \
-rd output=top_SR.gds \
-z -r addSR.rb

#fill
pwd_d=`pwd`
cd $OUTPUT ;\
$PVS \
-drc \
-top_cell top \
-ui_data \
-control $SCRIPT/pvsfillctl \
-cell_tree $OUTPUT/cell_tree.txt \
-dp 8 \
$RULE/Dummy_OD_PO_PVS_65nm.25a \
$RULE/Dummy_Metal_PVS_65nm.25a
cd $pwd_d

#make final gds
klayout \
-rd file1=top_SR.gds \
-rd file2=output/DODPO.gds \
-rd output=top_final.gds \
-z -r addSR.rb

#drc
pwd_d=`pwd`
cd $OUTPUT ;\
$PVS \
-drc \
-top_cell top \
-ui_data \
-control $SCRIPT/pvsdrcctl \
-cell_tree $OUTPUT/cell_tree.txt \
-dp 8 \
$RULE/PLN65S_9M_6X1Z1U.26a
cd $pwd_d


#wire bond drc
pwd_d=`pwd`
cd $OUTPUT ;\
$PVS \
-drc \
-top_cell top \
-ui_data \
-control $SCRIPT/pvswbctl \
-cell_tree $OUTPUT/cell_tree.txt \
-dp 8 \
$RULE/PN65_WIRE_BOND_CU_9M_6X1Z1U.14a
cd $pwd_d

#antenna drc
pwd_d=`pwd`
cd $OUTPUT ;\
$PVS \
-drc \
-top_cell top \
-ui_data \
-control $SCRIPT/pvsantctl \
-cell_tree $OUTPUT/cell_tree.txt \
-dp 8 \
$RULE/PN65S_9M_ANT.26a
cd $pwd_d
