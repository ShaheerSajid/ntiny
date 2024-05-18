# merge_files.rb 
#
# Merges two files into one
#
# Run this script with 
#   klayout -rd file1=first_file.gds -rd file2=second_file.gds -rd output=output_file.gds -z -r merge_files.rb
#
# (Note: -z puts KLayout into non-GUI mode)
#
# WARNING: this implementation merges the contents of all cells with identical names
# unless the cells are renamed (see comments)

ly1 = RBA::Layout::new
ly1.read($file1)

ly2 = RBA::Layout::new
ly2.read($file2)

ly1_top_cell = ly1.top_cell
new_cell = ly1.create_cell(ly2.top_cell.name)
new_cell.copy_tree(ly2.top_cell)
angle = 0
mirror = false
x= 0
y= 0
trans = RBA::Trans::new(angle,mirror,x,y)
ly1_top_cell.insert(RBA::CellInstArray::new(new_cell.cell_index,trans))
ly1.write($output)
